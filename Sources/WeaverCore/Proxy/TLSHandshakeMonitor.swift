import Foundation
import NIO
import NIOTLS

/// Sits just below the TLS handler on the client-facing side and reports when
/// the handshake never completes — the signature of certificate pinning (the
/// app rejects our leaf) or an untrusted CA on the device.
///
/// Without this, a pinned app produces no flow at all: the connection is
/// tunnelled (CONNECT succeeds) but the inner TLS handshake fails, so the user
/// sees an empty list and can't tell "broken" from "pinned". We surface a
/// single failure flow per connection instead.
final class TLSHandshakeMonitor: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private let host: String
    private let port: Int
    private weak var events: ProxyEventHandler?
    private let startedAt: Date
    private var settled = false

    init(host: String, port: Int, events: ProxyEventHandler?) {
        self.host = host
        self.port = port
        self.events = events
        self.startedAt = Date()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event {
            // Interception succeeded; nothing to report. Stay in the pipeline as a
            // transparent passthrough (removing a handler mid-event dispatch is
            // fragile and can disrupt the HTTP/2 negotiation that follows).
            settled = true
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Any error before the handshake completes is a handshake failure — the
        // only bytes exchanged so far are the TLS handshake itself.
        reportFailure(reason: "TLS handshake with the client failed (\(error)).")
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Client dropped the connection mid-handshake (common pinning behaviour:
        // send a TLS alert then RST, or just close).
        reportFailure(reason: "Client closed the connection during the TLS handshake.")
        context.fireChannelInactive()
    }

    private func reportFailure(reason: String) {
        guard !settled else { return }
        settled = true

        guard let url = URL(string: "https://\(host)\(port == 443 ? "" : ":\(port)")/") else { return }
        let flow = Flow(
            method: "TLS",
            url: url,
            scheme: "https",
            host: host,
            path: "/",
            isTLS: true
        )
        flow.tlsInterceptionFailed = true
        flow.error = reason + " Likely certificate pinning, or the CA is not trusted on the device."
        flow.completedAt = Date()
        events?.flowDidStart(flow)
        events?.flowDidComplete(flow)
    }
}
