import Foundation
import NIO

/// Relays a CONNECT tunnel byte-for-byte to the origin without terminating TLS.
///
/// Used for hosts on the bypass list: the client's own (possibly pinned) TLS
/// session passes straight through, so the app works normally and we never see
/// plaintext. We still record a minimal flow so the user can see the host was
/// tunnelled rather than silently ignored.
enum BlindTunnel {

    static func start(
        clientChannel: Channel,
        host: String,
        port: Int,
        events: ProxyEventHandler?
    ) {
        let flow = Flow(
            method: "CONNECT",
            url: URL(string: "https://\(host)\(port == 443 ? "" : ":\(port)")/") ?? URL(string: "https://\(host)/")!,
            scheme: "https",
            host: host,
            path: "/",
            isTLS: true
        )
        flow.bypassed = true
        flow.error = "Tunnelled without decryption (host is on the bypass list)."
        events?.flowDidStart(flow)

        // client writes to `toOrigin.channel`; origin writes to `toClient.channel`.
        let toOrigin = ChannelBox()
        let toClient = ChannelBox()
        toClient.channel = clientChannel

        let clientGlue = GlueHandler(peer: toOrigin)
        let originGlue = GlueHandler(peer: toClient)

        // Swap the HTTP proxy handlers for the raw client-side relay *first*, so
        // the client's TLS ClientHello isn't dropped while we dial the origin
        // (the glue buffers it until the origin side is connected).
        let removals = ["proxy-handler", "http-decoder", "http-encoder"].map {
            clientChannel.pipeline.removeHandler(name: $0)
        }
        EventLoopFuture.andAllComplete(removals, on: clientChannel.eventLoop).whenComplete { _ in
            do {
                try clientChannel.pipeline.syncOperations.addHandler(clientGlue, name: "glue")
            } catch {
                clientChannel.close(promise: nil)
                return
            }

            ClientBootstrap(group: clientChannel.eventLoop)
                .channelInitializer { origin in origin.pipeline.addHandler(originGlue) }
                .connect(host: host, port: port)
                .whenComplete { result in
                    switch result {
                    case .success(let originChannel):
                        toOrigin.channel = originChannel
                        clientGlue.flushPending()      // release any buffered ClientHello
                    case .failure(let error):
                        flow.error = "Bypass tunnel to \(host):\(port) failed: \(error)"
                        flow.completedAt = Date()
                        events?.flowDidComplete(flow)
                        clientChannel.close(promise: nil)
                    }
                }
        }

        clientChannel.closeFuture.whenComplete { _ in
            if flow.completedAt == nil {
                flow.completedAt = Date()
                events?.flowDidComplete(flow)
            }
        }
    }
}

/// Forwards inbound bytes to its peer channel, buffering until the peer exists.
/// One instance sits in each of the two tunnelled channels' pipelines.
final class GlueHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let peer: ChannelBox
    private var pending: [ByteBuffer] = []

    init(peer: ChannelBox) { self.peer = peer }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        if let peerChannel = peer.channel {
            peerChannel.writeAndFlush(buffer, promise: nil)
        } else {
            pending.append(buffer)
        }
    }

    /// Flush bytes that arrived before the peer channel was ready.
    func flushPending() {
        guard let peerChannel = peer.channel, !pending.isEmpty else { return }
        for buffer in pending { peerChannel.write(buffer, promise: nil) }
        peerChannel.flush()
        pending.removeAll()
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.channel?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
