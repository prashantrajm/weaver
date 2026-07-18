import Foundation
import NIO
import NIOHTTP1
import NIOSSL
import NIOWebSocket
import Crypto

/// Transparently intercepts a WebSocket upgrade so frames can be captured.
///
/// AsyncHTTPClient's buffered request/response path can't carry a long-lived
/// upgraded connection, so WebSocket is handled at the NIO level: we complete
/// the handshake with the upstream server, echo `101 Switching Protocols` back
/// to the client (with an Accept token derived from *its* key), then relay
/// frames in both directions — decoding a copy of each for the inspector.
enum WebSocketInterception {

    private static let magicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    private static let maxFrameSize = 16 * 1024 * 1024

    /// When false, the upstream (server-facing) TLS leg skips certificate
    /// verification. Off by default; used for local testing and as an optional
    /// "ignore upstream cert errors" mode.
    public static let verifyUpstreamCertificates = LockedFlag(true)

    static func start(
        channel clientChannel: Channel,
        head: HTTPRequestHead,
        absoluteURL: String,
        host: String,
        port: Int,
        isTLS: Bool,
        httpVersionLabel: String,
        events: ProxyEventHandler?
    ) {
        guard let url = URL(string: absoluteURL),
              let clientKey = head.headers.first(name: "sec-websocket-key") else {
            channel_closeBadRequest(clientChannel)
            return
        }

        let flow = Flow(
            method: "GET",
            url: url,
            scheme: isTLS ? "wss" : "ws",
            host: host,
            path: head.uri,
            requestHeaders: head.headers.map { HTTPHeader(name: $0.name, value: $0.value) },
            isTLS: isTLS,
            clientDescription: head.headers.first(name: "user-agent") ?? ""
        )
        flow.httpVersion = httpVersionLabel
        flow.isWebSocket = true
        events?.flowDidStart(flow)

        let acceptToken = computeAccept(key: clientKey)

        // Peer references: each relay writes frames to the *other* channel.
        let upstreamPeer = ChannelBox()      // upstream relay writes here → client
        upstreamPeer.channel = clientChannel
        let clientPeer = ChannelBox()        // client relay writes here → upstream (filled on connect)

        let upstreamRelay = WebSocketRelayHandler(
            peer: upstreamPeer, direction: .received, maskOutbound: false,
            flow: flow, events: events
        )
        let clientRelay = WebSocketRelayHandler(
            peer: clientPeer, direction: .sent, maskOutbound: true,
            flow: flow, events: events
        )

        // When upstream returns 101, switch BOTH pipelines to WebSocket within
        // the same event-loop tick so no frame slips through un-relayed.
        let onUpgrade: (HTTPResponseHead) -> Void = { upstreamResponse in
            do {
                var responseHeaders = HTTPHeaders()
                responseHeaders.add(name: "Upgrade", value: "websocket")
                responseHeaders.add(name: "Connection", value: "Upgrade")
                responseHeaders.add(name: "Sec-WebSocket-Accept", value: acceptToken)
                if let proto = upstreamResponse.headers.first(name: "sec-websocket-protocol") {
                    responseHeaders.add(name: "Sec-WebSocket-Protocol", value: proto)
                }
                let response = HTTPResponseHead(version: .http1_1, status: .switchingProtocols,
                                                headers: responseHeaders)
                clientChannel.write(NIOAny(HTTPServerResponsePart.head(response)), promise: nil)
                clientChannel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)

                flow.statusCode = 101
                events?.flowDidUpdate(flow)

                let removals = ["proxy-handler", "http-decoder", "http-encoder"].map {
                    clientChannel.pipeline.removeHandler(name: $0)
                }
                EventLoopFuture.andAllComplete(removals, on: clientChannel.eventLoop).whenComplete { _ in
                    do {
                        let sync = clientChannel.pipeline.syncOperations
                        try sync.addHandler(ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: maxFrameSize)))
                        try sync.addHandler(WebSocketFrameEncoder())
                        try sync.addHandler(clientRelay)
                    } catch {
                        events?.proxyDidLog("WebSocket client switch failed: \(error)")
                        clientChannel.close(promise: nil)
                    }
                }
            }
        }

        connectUpstream(
            on: clientChannel.eventLoop, host: host, port: port, isTLS: isTLS,
            head: head, upstreamRelay: upstreamRelay, onUpgrade: onUpgrade, events: events
        ).whenComplete { result in
            switch result {
            case .success(let upstreamChannel):
                clientPeer.channel = upstreamChannel
            case .failure(let error):
                flow.error = "WebSocket upstream failed: \(error)"
                flow.completedAt = Date()
                events?.flowDidComplete(flow)
                channel_closeBadRequest(clientChannel)
            }
        }
    }

    // MARK: - Upstream connection + handshake

    private static func connectUpstream(
        on eventLoop: EventLoop,
        host: String,
        port: Int,
        isTLS: Bool,
        head: HTTPRequestHead,
        upstreamRelay: WebSocketRelayHandler,
        onUpgrade: @escaping (HTTPResponseHead) -> Void,
        events: ProxyEventHandler?
    ) -> EventLoopFuture<Channel> {
        let bootstrap = ClientBootstrap(group: eventLoop)
            .channelInitializer { channel in
                do {
                    let sync = channel.pipeline.syncOperations
                    if isTLS {
                        var tls = TLSConfiguration.makeClientConfiguration()
                        tls.applicationProtocols = ["http/1.1"]
                        if !verifyUpstreamCertificates.value {
                            tls.certificateVerification = .none
                        }
                        let context = try NIOSSLContext(configuration: tls)
                        let serverName = Self.isIPAddress(host) ? nil : host
                        try sync.addHandler(try NIOSSLClientHandler(context: context, serverHostname: serverName))
                    }
                    try sync.addHandler(HTTPRequestEncoder(), name: "up-encoder")
                    try sync.addHandler(ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)),
                                        name: "up-decoder")
                    try sync.addHandler(UpstreamHandshakeHandler(
                        relay: upstreamRelay, onUpgrade: onUpgrade,
                        maxFrameSize: maxFrameSize, events: events
                    ), name: "up-handshake")
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        return bootstrap.connect(host: host, port: port).flatMapThrowing { channel in
            // Replay the client's upgrade request to the upstream server.
            var headers = head.headers
            headers.replaceOrAdd(name: "Host", value: port == (isTLS ? 443 : 80) ? host : "\(host):\(port)")
            headers.remove(name: "Proxy-Connection")
            let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: head.uri, headers: headers)
            channel.write(NIOAny(HTTPClientRequestPart.head(requestHead)), promise: nil)
            channel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil)), promise: nil)
            return channel
        }
    }

    // MARK: - Helpers

    private static func computeAccept(key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + magicGUID).utf8))
        return Data(digest).base64EncodedString()
    }

    private static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr(); var v6 = in6_addr()
        return host.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }

    private static func channel_closeBadRequest(_ channel: Channel) {
        let head = HTTPResponseHead(version: .http1_1, status: .badGateway)
        channel.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
        channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}

/// Holds a peer channel reference for a relay handler (set once both sides exist).
final class ChannelBox: @unchecked Sendable {
    var channel: Channel?
}

/// A minimal thread-safe boolean flag.
public final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool
    public init(_ value: Bool) { self._value = value }
    public var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// Reads the upstream server's `101` response, then swaps the upstream pipeline
/// to WebSocket framing and hands control back via `onUpgrade`.
private final class UpstreamHandshakeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let relay: WebSocketRelayHandler
    private let onUpgrade: (HTTPResponseHead) -> Void
    private let maxFrameSize: Int
    private weak var events: ProxyEventHandler?
    private var upgraded = false

    init(relay: WebSocketRelayHandler, onUpgrade: @escaping (HTTPResponseHead) -> Void,
         maxFrameSize: Int, events: ProxyEventHandler?) {
        self.relay = relay
        self.onUpgrade = onUpgrade
        self.maxFrameSize = maxFrameSize
        self.events = events
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !upgraded else { return }
        let part = unwrapInboundIn(data)
        guard case .head(let responseHead) = part else { return }

        guard responseHead.status == .switchingProtocols else {
            events?.proxyDidLog("WebSocket upstream refused upgrade: \(responseHead.status.code)")
            context.close(promise: nil)
            return
        }
        upgraded = true

        let channel = context.channel
        let relay = self.relay
        let maxFrameSize = self.maxFrameSize
        let onUpgrade = self.onUpgrade

        let removals = ["up-encoder", "up-decoder", "up-handshake"].map {
            channel.pipeline.removeHandler(name: $0)
        }
        EventLoopFuture.andAllComplete(removals, on: channel.eventLoop).whenComplete { _ in
            do {
                let sync = channel.pipeline.syncOperations
                try sync.addHandler(ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: maxFrameSize)))
                try sync.addHandler(WebSocketFrameEncoder())
                try sync.addHandler(relay)
                onUpgrade(responseHead)
            } catch {
                channel.close(promise: nil)
            }
        }
    }
}

/// Relays one direction of a bridged WebSocket, capturing each frame. Frames
/// forwarded toward a server are masked (WE act as the client); frames toward
/// the client are unmasked (WE act as the server).
final class WebSocketRelayHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let peer: ChannelBox
    private let direction: WebSocketMessage.Direction
    private let maskOutbound: Bool
    private let flow: Flow
    private weak var events: ProxyEventHandler?

    init(peer: ChannelBox, direction: WebSocketMessage.Direction, maskOutbound: Bool,
         flow: Flow, events: ProxyEventHandler?) {
        self.peer = peer
        self.direction = direction
        self.maskOutbound = maskOutbound
        self.flow = flow
        self.events = events
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        capture(frame)

        guard let peerChannel = peer.channel else { return }
        var payload = frame.unmaskedData
        let outbound = WebSocketFrame(
            fin: frame.fin,
            opcode: frame.opcode,
            maskKey: maskOutbound ? Self.randomMaskKey() : nil,
            data: payload
        )
        _ = payload.readableBytes
        peerChannel.writeAndFlush(NIOAny(outbound), promise: nil)

        if frame.opcode == .connectionClose {
            flow.completedAt = Date()
            events?.flowDidComplete(flow)
            peerChannel.close(mode: .all, promise: nil)
            context.close(mode: .all, promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if flow.completedAt == nil {
            flow.completedAt = Date()
            events?.flowDidComplete(flow)
        }
        peer.channel?.close(promise: nil)
        context.fireChannelInactive()
    }

    private func capture(_ frame: WebSocketFrame) {
        let kind: WebSocketMessage.Kind
        switch frame.opcode {
        case .text: kind = .text
        case .binary, .continuation: kind = .binary
        case .ping: kind = .ping
        case .pong: kind = .pong
        case .connectionClose: kind = .close
        default: return
        }
        // Skip heartbeat noise in the captured list; still relayed above.
        if kind == .ping || kind == .pong { return }

        var buffer = frame.unmaskedData
        let payload = buffer.readData(length: buffer.readableBytes) ?? Data()
        flow.webSocketMessages.append(
            WebSocketMessage(direction: direction, kind: kind, payload: payload)
        )
        events?.flowDidUpdate(flow)
    }

    private static func randomMaskKey() -> WebSocketMaskingKey {
        WebSocketMaskingKey((0..<4).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })!
    }
}
