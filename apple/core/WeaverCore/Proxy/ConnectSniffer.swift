import Foundation
import NIO
import NIOHTTP1
import NIOSSL
import AsyncHTTPClient

/// First handler on every accepted connection. It reads the raw bytes at the
/// byte level (not via an HTTP decoder) so it can consume *exactly* the initial
/// request head and hand any trailing bytes onward untouched.
///
/// This precision matters for `CONNECT`: a client (notably iOS) sends its TLS
/// `ClientHello` immediately after the `CONNECT` line, often in the same TCP
/// segment. An `HTTPRequestDecoder` left in the pipeline would try to parse
/// those TLS bytes as the next HTTP request and consume the leading byte(s),
/// so the TLS server would then see an offset record and fail with
/// `WRONG_VERSION_NUMBER`. Here we split the buffer precisely and replay the
/// exact ClientHello into the TLS handler.
final class ConnectSniffer: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    static let name = "connect-sniffer"

    private let ca: CertificateAuthority
    private weak var events: ProxyEventHandler?
    private let httpClient: HTTPClient
    private let filter: HostFilter?

    private var buffer: ByteBuffer?
    private var handled = false

    init(ca: CertificateAuthority, events: ProxyEventHandler?, httpClient: HTTPClient, filter: HostFilter?) {
        self.ca = ca
        self.events = events
        self.httpClient = httpClient
        self.filter = filter
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !handled else {
            context.fireChannelRead(data)
            return
        }
        var incoming = unwrapInboundIn(data)
        if buffer == nil {
            buffer = context.channel.allocator.buffer(capacity: incoming.readableBytes)
        }
        buffer!.writeBuffer(&incoming)

        guard let bytes = buffer!.getBytes(at: buffer!.readerIndex, length: buffer!.readableBytes),
              let headerEnd = Self.indexAfterDoubleCRLF(bytes) else {
            if (buffer?.readableBytes ?? 0) > 64 * 1024 { context.close(promise: nil) } // runaway guard
            return
        }
        handled = true

        let requestLine = Self.firstLine(bytes)
        if requestLine.uppercased().hasPrefix("CONNECT ") {
            let authority = requestLine.split(separator: " ").count >= 2
                ? String(requestLine.split(separator: " ")[1]) : ""
            let leftover = headerEnd < bytes.count ? Array(bytes[headerEnd...]) : []
            handleConnect(context: context, authority: authority, leftover: leftover)
        } else {
            handlePlainHTTP(context: context)
        }
    }

    // MARK: - CONNECT

    private func handleConnect(context: ChannelHandlerContext, authority: String, leftover: [UInt8]) {
        let (host, port) = ProxyConnectionHandler.splitAuthority(authority, defaultPort: 443)

        // Raw 200 so nothing re-frames it; the tunnel is now transparent.
        var ok = context.channel.allocator.buffer(capacity: 40)
        ok.writeString("HTTP/1.1 200 Connection Established\r\n\r\n")
        context.writeAndFlush(wrapOutboundOut(ok), promise: nil)

        if filter?.shouldBypass(host) == true {
            let seed: ByteBuffer? = leftover.isEmpty ? nil : context.channel.allocator.buffer(bytes: leftover)
            let channel = context.channel
            let events = self.events
            context.pipeline.removeHandler(name: Self.name).whenComplete { _ in
                BlindTunnel.start(clientChannel: channel, host: host, port: port,
                                  events: events, initialClientBytes: seed)
            }
            return
        }

        do {
            let leaf = try ca.leaf(forHost: host)
            let sslContext = try TLSIdentity.serverContext(for: leaf, caCertificate: ca.certificate)
            let sync = context.pipeline.syncOperations
            try sync.addHandler(NIOSSLServerHandler(context: sslContext), name: "tls")
            try sync.addHandler(TLSHandshakeMonitor(host: host, port: port, events: events), name: "tls-monitor")

            ServerPipeline.configureAfterTLS(
                channel: context.channel, host: host, port: port,
                ca: ca, events: events, httpClient: httpClient
            ).whenComplete { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    // Replay the exact ClientHello into the now-present TLS handler,
                    // then step out so subsequent bytes flow straight to TLS.
                    if !leftover.isEmpty {
                        let hello = context.channel.allocator.buffer(bytes: leftover)
                        context.fireChannelRead(NIOAny(hello))
                    }
                    context.pipeline.removeHandler(name: Self.name, promise: nil)
                case .failure(let error):
                    self.events?.proxyDidLog("Pipeline setup failed for \(host): \(error)")
                    context.close(promise: nil)
                }
            }
        } catch {
            events?.proxyDidLog("TLS interception failed for \(host): \(error)")
            context.close(promise: nil)
        }
    }

    // MARK: - Plain HTTP

    private func handlePlainHTTP(context: ChannelHandlerContext) {
        do {
            let sync = context.pipeline.syncOperations
            try sync.addHandler(
                ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                name: "http-decoder"
            )
            try sync.addHandler(HTTPResponseEncoder(), name: "http-encoder")
            try sync.addHandler(
                ProxyConnectionHandler(ca: ca, events: events, httpClient: httpClient, filter: filter),
                name: "proxy-handler"
            )
            // Replay everything we buffered so the HTTP pipeline parses it.
            if let buffered = buffer {
                context.fireChannelRead(NIOAny(buffered))
            }
            context.pipeline.removeHandler(name: Self.name, promise: nil)
        } catch {
            context.close(promise: nil)
        }
    }

    // MARK: - Parsing helpers

    /// Returns the index just past the first `\r\n\r\n`, or nil if not present.
    static func indexAfterDoubleCRLF(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        var i = 0
        while i <= bytes.count - 4 {
            if bytes[i] == 13, bytes[i + 1] == 10, bytes[i + 2] == 13, bytes[i + 3] == 10 {
                return i + 4
            }
            i += 1
        }
        return nil
    }

    static func firstLine(_ bytes: [UInt8]) -> String {
        var line: [UInt8] = []
        for b in bytes {
            if b == 13 || b == 10 { break }
            line.append(b)
        }
        return String(decoding: line, as: UTF8.self)
    }
}
