import XCTest
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import NIOWebSocket
import Crypto
@testable import WeaverCore

final class WebSocketHandshakeMathTests: XCTestCase {
    func testAcceptTokenMatchesRFC6455Example() {
        // From RFC 6455 §1.3.
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        XCTAssertEqual(Data(digest).base64EncodedString(), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }
}

/// End-to-end WebSocket interception: a client tunnels through the proxy
/// (CONNECT → TLS → upgrade) to a local TLS echo server; the proxy should
/// decrypt, relay frames both ways, and capture them on the flow.
final class WebSocketE2ETests: XCTestCase {

    final class Recorder: ProxyEventHandler, @unchecked Sendable {
        let lock = NSLock()
        var flows: [Flow] = []
        func flowDidStart(_ flow: Flow) { lock.lock(); flows.append(flow); lock.unlock() }
        func flowDidComplete(_ flow: Flow) {}
        func proxyDidLog(_ message: String) {}
        func snapshot() -> [Flow] { lock.lock(); defer { lock.unlock() }; return flows }
    }

    func testCapturesWebSocketMessages() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        addTeardownBlock { try? group.syncShutdownGracefully() }

        // Upstream: a self-signed TLS WebSocket echo server (identity via our CA).
        let upstreamCA = try CertificateAuthority.generate()
        let echoPort = try startTLSEchoServer(group: group, ca: upstreamCA)

        // Proxy: trust its own CA on the client leg; skip upstream verification
        // since the echo server is self-signed.
        WebSocketInterception.verifyUpstreamCertificates.value = false
        defer { WebSocketInterception.verifyUpstreamCertificates.value = true }

        let proxyCA = try CertificateAuthority.generate()
        let recorder = Recorder()
        let proxyPort = Int.random(in: 20000...40000)
        let proxy = ProxyServer(host: "127.0.0.1", port: proxyPort, ca: proxyCA, events: recorder)
        try proxy.start()
        defer { proxy.shutdown() }

        // Client: CONNECT through the proxy, TLS trusting the proxy CA, then WS.
        let received = try await runWebSocketClient(
            group: group, proxyPort: proxyPort, echoHost: "localhost", echoPort: echoPort,
            proxyCA: proxyCA, message: "ping-123"
        )
        XCTAssertEqual(received, "ping-123", "echo should round-trip through the proxy")

        // The proxy should have captured both directions.
        try await Task.sleep(nanoseconds: 200_000_000)
        let flows = recorder.snapshot()
        let ws = flows.first { $0.isWebSocket }
        XCTAssertNotNil(ws, "a WebSocket flow should be captured")
        XCTAssertEqual(ws?.statusCode, 101)
        let sent = ws?.webSocketMessages.filter { $0.direction == .sent } ?? []
        let recv = ws?.webSocketMessages.filter { $0.direction == .received } ?? []
        XCTAssertTrue(sent.contains { $0.textPreview == "ping-123" }, "captured a sent frame")
        XCTAssertTrue(recv.contains { $0.textPreview == "ping-123" }, "captured a received frame")
    }

    // MARK: - Local TLS WebSocket echo server

    private func startTLSEchoServer(group: EventLoopGroup, ca: CertificateAuthority) throws -> Int {
        let leaf = try ca.leaf(forHost: "localhost")
        let sslContext = try TLSIdentity.serverContext(for: leaf, caCertificate: ca.certificate)

        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { channel, _ in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
            upgradePipelineHandler: { channel, _ in
                channel.pipeline.addHandler(EchoFrameHandler())
            }
        )
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(NIOSSLServerHandler(context: sslContext)).flatMap {
                    channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (
                        upgraders: [upgrader],
                        completionHandler: { _ in }
                    ))
                }
            }
        let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        return channel.localAddress!.port!
    }

    // MARK: - WebSocket client through the proxy

    private func runWebSocketClient(
        group: EventLoopGroup, proxyPort: Int, echoHost: String, echoPort: Int,
        proxyCA: CertificateAuthority, message: String
    ) async throws -> String {
        let caCert = try NIOSSLCertificate(bytes: Array(try proxyCA.certificatePEM().utf8), format: .pem)
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.trustRoots = .certificates([caCert])
        tls.applicationProtocols = ["http/1.1"]
        let clientSSL = try NIOSSLContext(configuration: tls)

        let resultPromise = group.next().makePromise(of: String.self)
        group.next().scheduleTask(in: .seconds(10)) {
            resultPromise.fail(WSClientError.connectFailed("timed out"))
        }

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(
                    ProxyConnectAndUpgradeHandler(
                        sslContext: clientSSL, serverHostname: echoHost, echoHost: echoHost,
                        echoPort: echoPort, message: message, resultPromise: resultPromise
                    )
                )
            }
        _ = try await bootstrap.connect(host: "127.0.0.1", port: proxyPort).get()
        return try await resultPromise.futureResult.get()
    }
}

/// Server-side echo: reflects text/binary frames back to the client.
private final class EchoFrameHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text, .binary:
            let echo = WebSocketFrame(fin: true, opcode: frame.opcode, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(echo), promise: nil)
        case .connectionClose:
            context.close(promise: nil)
        default:
            break
        }
    }
}

/// Client driver: sends CONNECT, starts TLS, performs the WS upgrade, sends one
/// text frame, and resolves with the echoed text.
private final class ProxyConnectAndUpgradeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    enum Phase { case connecting, tunneled }
    private var phase: Phase = .connecting
    private var connectBuffer = ""

    private let sslContext: NIOSSLContext
    private let serverHostname: String
    private let echoHost: String
    private let echoPort: Int
    private let message: String
    private let resultPromise: EventLoopPromise<String>

    init(sslContext: NIOSSLContext, serverHostname: String, echoHost: String,
         echoPort: Int, message: String, resultPromise: EventLoopPromise<String>) {
        self.sslContext = sslContext
        self.serverHostname = serverHostname
        self.echoHost = echoHost
        self.echoPort = echoPort
        self.message = message
        self.resultPromise = resultPromise
    }

    func channelActive(context: ChannelHandlerContext) {
        let connect = "CONNECT \(echoHost):\(echoPort) HTTP/1.1\r\nHost: \(echoHost):\(echoPort)\r\n\r\n"
        var buf = context.channel.allocator.buffer(capacity: connect.utf8.count)
        buf.writeString(connect)
        context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard phase == .connecting else { return }   // post-tunnel reads handled downstream
        var buffer = unwrapInboundIn(data)
        connectBuffer += buffer.readString(length: buffer.readableBytes) ?? ""
        guard connectBuffer.contains("\r\n\r\n") else { return }
        guard connectBuffer.contains(" 200 ") else {
            resultPromise.fail(WSClientError.connectFailed(connectBuffer)); return
        }
        phase = .tunneled
        upgradeToTLSAndWebSocket(context: context)
    }

    private func upgradeToTLSAndWebSocket(context: ChannelHandlerContext) {
        let channel = context.channel
        let promise = resultPromise
        let message = self.message
        do {
            let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: serverHostname)
            let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()

            let wsUpgrader = NIOWebSocketClientUpgrader(
                requestKey: key,
                upgradePipelineHandler: { ch, _ in
                    ch.pipeline.addHandler(WSClientFrameHandler(message: message, promise: promise))
                }
            )
            let upgradeConfig: NIOHTTPClientUpgradeConfiguration = (
                upgraders: [wsUpgrader],
                completionHandler: { _ in }
            )

            try channel.pipeline.syncOperations.addHandler(sslHandler, position: .first)
            try channel.pipeline.syncOperations.removeHandler(self)
            channel.pipeline.addHTTPClientHandlers(withClientUpgrade: upgradeConfig).whenSuccess {
                var headers = HTTPHeaders()
                headers.add(name: "Host", value: "\(self.echoHost):\(self.echoPort)")
                headers.add(name: "Content-Length", value: "0")
                let request = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: headers)
                channel.write(NIOAny(HTTPClientRequestPart.head(request)), promise: nil)
                channel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil)), promise: nil)
            }
        } catch {
            promise.fail(error)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        resultPromise.fail(error)
        context.close(promise: nil)
    }
}

private final class WSClientFrameHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    private let message: String
    private let promise: EventLoopPromise<String>

    init(message: String, promise: EventLoopPromise<String>) {
        self.message = message
        self.promise = promise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Added post-upgrade to an already-active channel, so channelActive won't
        // fire; send the first frame here.
        var payload = context.channel.allocator.buffer(capacity: message.utf8.count)
        payload.writeString(message)
        let maskKey = WebSocketMaskingKey((0..<4).map { _ in UInt8.random(in: .min ... .max) })!
        let frame = WebSocketFrame(fin: true, opcode: .text, maskKey: maskKey, data: payload)
        context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        if frame.opcode == .text {
            var body = frame.unmaskedData
            let text = body.readString(length: body.readableBytes) ?? ""
            promise.succeed(text)
        }
    }
}

private enum WSClientError: Error { case connectFailed(String) }
