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

    private let group: EventLoopGroup
    private var channel: Channel?
    private let httpClient: HTTPClient

    public private(set) var state: ProxyState = .stopped

    public init(host: String = "127.0.0.1", port: Int = 9090, ca: CertificateAuthority, events: ProxyEventHandler?) {
        self.host = host
        self.port = port
        self.ca = ca
        self.events = events
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

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
            .childChannelInitializer { [ca, events, httpClient] channel in
                let handler = ProxyConnectionHandler(ca: ca, events: events, httpClient: httpClient)
                do {
                    let sync = channel.pipeline.syncOperations
                    try sync.addHandler(
                        ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                        name: "http-decoder"
                    )
                    try sync.addHandler(HTTPResponseEncoder(), name: "http-encoder")
                    try sync.addHandler(handler, name: "proxy-handler")
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
