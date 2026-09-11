import Foundation
import NIO
import NIOHTTP1
import NIOSSL
import AsyncHTTPClient

/// Receives live capture events. The macOS app implements this to drive the UI.
public protocol ProxyEventHandler: AnyObject, Sendable {
    func flowDidStart(_ flow: Flow)
    func flowDidComplete(_ flow: Flow)
    func proxyDidLog(_ message: String)
    /// Fired when an already-started flow mutates in place (e.g. a new
    /// WebSocket frame is appended). Optional; defaults to a no-op.
    func flowDidUpdate(_ flow: Flow)
}

public extension ProxyEventHandler {
    func flowDidUpdate(_ flow: Flow) {}
}

public enum ProxyState: Equatable, Sendable {
    case stopped
    case running(host: String, port: Int)
    case failed(String)
}

/// The local HTTP/HTTPS intercepting proxy (M1.1).
///
/// Clients point their system/Wi-Fi proxy at this listener. Plain HTTP is
/// forwarded and captured directly; HTTPS arrives as `CONNECT`, at which point
/// we present a leaf cert minted by our CA, terminate TLS, inspect the
/// decrypted HTTP, and forward it upstream via AsyncHTTPClient.
public final class ProxyServer: @unchecked Sendable {

    public let host: String
    public let port: Int
    private let ca: CertificateAuthority
    private weak var events: ProxyEventHandler?
    private let filter: HostFilter
    private let clientResolver: ClientResolver?
    /// Per-connection taggers, retained for the life of their connection
    /// (handlers only hold them weakly). See `ConnectionEventTagger`.
    private let liveTaggers = LockedDictionary<ObjectIdentifier, ConnectionEventTagger>()

    private let group: EventLoopGroup
    private var channel: Channel?
    private let httpClient: HTTPClient

    public private(set) var state: ProxyState = .stopped

    /// - Parameters:
    ///   - threads: event-loop thread count. Defaults to the core count; pass a
    ///     small number (e.g. 2) inside the memory-capped iOS packet-tunnel
    ///     extension to keep the footprint down.
    ///   - clientResolver: attributes loopback connections to the local process
    ///     that opened them (macOS: `LocalProcessResolver`). Nil disables it.
    public init(host: String = "127.0.0.1", port: Int = 9090, ca: CertificateAuthority,
                events: ProxyEventHandler?, filter: HostFilter = HostFilter(),
                threads: Int = System.coreCount, clientResolver: ClientResolver? = nil) {
        self.host = host
        self.port = port
        self.ca = ca
        self.events = events
        self.filter = filter
        self.clientResolver = clientResolver
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: max(1, threads))

        var clientConfig = HTTPClient.Configuration()
        clientConfig.redirectConfiguration = .disallow   // capture redirects as their own flows
        clientConfig.decompression = .disabled           // show bytes as the server sent them
        self.httpClient = HTTPClient(eventLoopGroupProvider: .shared(group), configuration: clientConfig)
    }

    public func start() throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [ca, httpClient, filter] channel in
                let events = self.eventHandler(for: channel)
                // A byte-level sniffer parses the initial request head precisely,
                // so a pipelined TLS ClientHello after CONNECT is handed to the
                // TLS handler untouched (see ConnectSniffer).
                let sniffer = ConnectSniffer(ca: ca, events: events, httpClient: httpClient, filter: filter)
                do {
                    try channel.pipeline.syncOperations.addHandler(sniffer, name: ConnectSniffer.name)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        do {
            let channel = try bootstrap.bind(host: host, port: port).wait()
            self.channel = channel
            self.state = .running(host: host, port: port)
            events?.proxyDidLog("Listening on \(host):\(port)")
        } catch {
            self.state = .failed(String(describing: error))
            throw error
        }
    }

    /// For a loopback client with a resolver configured, wrap the events in a
    /// per-connection tagger and kick off process resolution; otherwise the
    /// shared handler is used directly (devices on the LAN, iOS tunnel).
    private func eventHandler(for channel: Channel) -> ProxyEventHandler? {
        guard let clientResolver,
              let remote = channel.remoteAddress, let clientPort = remote.port,
              Self.isLoopback(remote) else { return events }

        let tagger = ConnectionEventTagger(upstream: events)
        let key = ObjectIdentifier(tagger)
        liveTaggers[key] = tagger
        channel.closeFuture.whenComplete { [liveTaggers] _ in liveTaggers[key] = nil }

        clientResolver.resolve(clientPort: clientPort, proxyPort: port) { process in
            tagger.resolved(process)
        }
        return tagger
    }

    static func isLoopback(_ address: SocketAddress) -> Bool {
        guard let ip = address.ipAddress else { return false }
        return ip.hasPrefix("127.") || ip == "::1" || ip.hasPrefix("::ffff:127.")
    }

    public func stop() {
        try? channel?.close().wait()
        channel = nil
        state = .stopped
        events?.proxyDidLog("Stopped")
    }

    public func shutdown() {
        stop()
        try? httpClient.syncShutdown()
        try? group.syncShutdownGracefully()
    }
}

/// Minimal thread-safe dictionary (NSLock-guarded) for bookkeeping shared
/// between event-loop threads.
final class LockedDictionary<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Key: Value] = [:]

    subscript(key: Key) -> Value? {
        get { lock.lock(); defer { lock.unlock() }; return storage[key] }
        set { lock.lock(); storage[key] = newValue; lock.unlock() }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return storage.count }
}
