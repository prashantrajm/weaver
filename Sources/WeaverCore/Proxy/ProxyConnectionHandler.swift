import Foundation
import NIO
import NIOHTTP1
import NIOSSL
import AsyncHTTPClient

/// Per-connection handler. Operates in one of two modes:
///
/// - **top level** (`interceptedHost == nil`): the first request decides the
///   path. `CONNECT` triggers TLS interception (reconfigures the pipeline with
///   a leaf cert and re-enters in MITM mode); anything else is a plain-HTTP
///   proxy request forwarded upstream and captured.
/// - **MITM** (`interceptedHost != nil`): runs *inside* the terminated TLS
///   session. Requests carry only a path, so we rebuild the absolute `https`
///   URL from the intercepted host.
final class ProxyConnectionHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let ca: CertificateAuthority
    private weak var events: ProxyEventHandler?
    private let httpClient: HTTPClient
    private let interceptedHost: String?
    private let interceptedPort: Int
    private let httpVersionLabel: String

    // Per-request accumulation.
    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?

    init(ca: CertificateAuthority, events: ProxyEventHandler?, httpClient: HTTPClient,
         interceptedHost: String? = nil, interceptedPort: Int = 443,
         httpVersionLabel: String = "HTTP/1.1") {
        self.ca = ca
        self.events = events
        self.httpClient = httpClient
        self.interceptedHost = interceptedHost
        self.interceptedPort = interceptedPort
        self.httpVersionLabel = httpVersionLabel
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            if interceptedHost == nil && head.method == .CONNECT {
                startTLSInterception(context: context, authority: head.uri)
                return
            }
            requestHead = head
            bodyBuffer = context.channel.allocator.buffer(capacity: 0)

        case .body(var chunk):
            bodyBuffer?.writeBuffer(&chunk)

        case .end:
            guard let head = requestHead else { return }
            if Self.isWebSocketUpgrade(head) {
                startWebSocketInterception(context: context, head: head)
            } else {
                forward(context: context, head: head, body: bodyBuffer)
            }
            requestHead = nil
            bodyBuffer = nil
        }
    }

    private static func isWebSocketUpgrade(_ head: HTTPRequestHead) -> Bool {
        let upgrade = head.headers[canonicalForm: "upgrade"].map { $0.lowercased() }
        let connection = head.headers[canonicalForm: "connection"].map { $0.lowercased() }
        return upgrade.contains("websocket") && connection.contains("upgrade")
    }

    private func startWebSocketInterception(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let scheme = interceptedHost == nil ? "ws" : "wss"
        let (absoluteURLString, host) = Self.resolveURL(head: head, scheme: scheme,
                                                        interceptedHost: interceptedHost)
        let port = interceptedHost == nil
            ? (head.headers.first(name: "host").flatMap { Self.splitAuthority($0, defaultPort: 80).1 } ?? 80)
            : interceptedPort
        WebSocketInterception.start(
            channel: context.channel,
            head: head,
            absoluteURL: absoluteURLString,
            host: host,
            port: port,
            isTLS: interceptedHost != nil,
            httpVersionLabel: httpVersionLabel,
            events: events
        )
    }

    // MARK: - CONNECT → TLS interception

    private func startTLSInterception(context: ChannelHandlerContext, authority: String) {
        let (host, port) = Self.splitAuthority(authority, defaultPort: 443)

        // Acknowledge the tunnel so the client begins its TLS handshake with us.
        var headers = HTTPHeaders()
        headers.add(name: "Connection", value: "keep-alive")
        let responseHead = HTTPResponseHead(
            version: .http1_1,
            status: .custom(code: 200, reasonPhrase: "Connection Established"),
            headers: HTTPHeaders()
        )
        _ = headers
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)

        let channel = context.channel
        let ca = self.ca
        let events = self.events
        let httpClient = self.httpClient

        // Swap the plain HTTP pipeline for: TLS server → HTTP server → MITM handler.
        let removals = ["http-decoder", "http-encoder", "proxy-handler"].map { name in
            channel.pipeline.removeHandler(name: name)
        }
        EventLoopFuture.andAllComplete(removals, on: channel.eventLoop).whenComplete { _ in
            do {
                let leaf = try ca.leaf(forHost: host)
                let sslContext = try TLSIdentity.serverContext(for: leaf, caCertificate: ca.certificate)
                let sslHandler = NIOSSLServerHandler(context: sslContext)
                try channel.pipeline.syncOperations.addHandler(sslHandler, name: "tls")
                // Watch the client-facing handshake so pinning failures surface
                // as a flow instead of a silent close.
                try channel.pipeline.syncOperations.addHandler(
                    TLSHandshakeMonitor(host: host, port: port, events: events),
                    name: "tls-monitor"
                )
                // ALPN then selects the HTTP/1.1 or HTTP/2 pipeline.
                ServerPipeline.configureAfterTLS(
                    channel: channel, host: host, port: port,
                    ca: ca, events: events, httpClient: httpClient
                ).whenFailure { error in
                    events?.proxyDidLog("HTTP pipeline setup failed for \(host): \(error)")
                    channel.close(promise: nil)
                }
            } catch {
                events?.proxyDidLog("TLS interception failed for \(host): \(error)")
                channel.close(promise: nil)
            }
        }
    }

    // MARK: - Forwarding

    private func forward(context: ChannelHandlerContext, head: HTTPRequestHead, body: ByteBuffer?) {
        let scheme = interceptedHost == nil ? "http" : "https"
        let (absoluteURLString, host) = Self.resolveURL(head: head, scheme: scheme,
                                                        interceptedHost: interceptedHost)
        guard let url = URL(string: absoluteURLString) else {
            events?.proxyDidLog("Bad URL: \(absoluteURLString)")
            respondError(context: context, status: .badRequest)
            return
        }

        let requestHeaders = head.headers.map { HTTPHeader(name: $0.name, value: $0.value) }
        var bodyData: Data?
        if var body, body.readableBytes > 0 {
            bodyData = body.readData(length: body.readableBytes)
        }

        let flow = Flow(
            method: head.method.rawValue,
            url: url,
            scheme: scheme,
            host: host,
            path: head.uri.hasPrefix("/") ? head.uri : (url.path.isEmpty ? "/" : url.path),
            requestHeaders: requestHeaders,
            requestBody: bodyData,
            isTLS: scheme == "https",
            clientDescription: head.headers.first(name: "user-agent") ?? ""
        )
        flow.httpVersion = httpVersionLabel
        events?.flowDidStart(flow)

        var clientRequest: HTTPClientRequest
        do {
            clientRequest = HTTPClientRequest(url: absoluteURLString)
        } catch {
            finishWithError(context: context, flow: flow, error: error)
            return
        }
        clientRequest.method = head.method
        for header in head.headers {
            let lower = header.name.lowercased()
            if lower == "proxy-connection" || lower == "connection" { continue }
            clientRequest.headers.add(name: header.name, value: header.value)
        }
        if let bodyData {
            clientRequest.body = .bytes(ByteBuffer(bytes: bodyData))
        }

        let channel = context.channel
        let httpClient = self.httpClient
        let events = self.events

        channel.eventLoop.makeFutureWithTask {
            try await Self.performUpstream(httpClient: httpClient, request: clientRequest)
        }.whenComplete { result in
            switch result {
            case .success(let captured):
                flow.statusCode = Int(captured.status.code)
                // Keep the original headers for the inspector (transparency),
                // even though we may strip h3 Alt-Svc from what the client gets.
                flow.responseHeaders = captured.headers.map { HTTPHeader(name: $0.name, value: $0.value) }
                flow.serverAdvertisedHTTP3 = HTTP3Policy.advertisesHTTP3(captured.headers)
                flow.responseBody = captured.body.isEmpty ? nil : captured.body
                flow.completedAt = Date()
                events?.flowDidComplete(flow)
                let outHeaders = HTTP3Policy.blockHTTP3.value
                    ? HTTP3Policy.stripHTTP3AltSvc(captured.headers)
                    : captured.headers
                Self.writeResponse(channel: channel, status: captured.status,
                                   headers: outHeaders, body: captured.body)
            case .failure(let error):
                self.finishWithError(context: nil, channel: channel, flow: flow, error: error)
            }
        }
    }

    private struct UpstreamResult {
        let status: HTTPResponseStatus
        let headers: HTTPHeaders
        let body: Data
    }

    private static func performUpstream(httpClient: HTTPClient, request: HTTPClientRequest) async throws -> UpstreamResult {
        let response = try await httpClient.execute(request, timeout: .seconds(30))
        var collected = Data()
        for try await chunk in response.body {
            collected.append(contentsOf: chunk.readableBytesView)
            if collected.count > 50 * 1024 * 1024 { break } // 50MB inspector cap
        }
        return UpstreamResult(status: response.status, headers: response.headers, body: collected)
    }

    private static func writeResponse(channel: Channel, status: HTTPResponseStatus, headers: HTTPHeaders, body: Data) {
        var outHeaders = headers
        // We fully buffer, so replace chunked framing with an explicit length.
        outHeaders.remove(name: "Transfer-Encoding")
        outHeaders.replaceOrAdd(name: "Content-Length", value: String(body.count))
        outHeaders.replaceOrAdd(name: "Connection", value: "keep-alive")

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: outHeaders)
        channel.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
        if !body.isEmpty {
            var buffer = channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
        }
        channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
    }

    private func respondError(context: ChannelHandlerContext, status: HTTPResponseStatus) {
        let head = HTTPResponseHead(version: .http1_1, status: status)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func finishWithError(context: ChannelHandlerContext?, channel: Channel? = nil, flow: Flow, error: Error) {
        flow.error = String(describing: error)
        flow.completedAt = Date()
        events?.flowDidComplete(flow)
        let head = HTTPResponseHead(version: .http1_1, status: .badGateway)
        let target = channel ?? context?.channel
        target?.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
        target?.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        events?.proxyDidLog("Connection error: \(error)")
        context.close(promise: nil)
    }

    // MARK: - Helpers

    static func splitAuthority(_ authority: String, defaultPort: Int) -> (String, Int) {
        if let colon = authority.lastIndex(of: ":"),
           let port = Int(authority[authority.index(after: colon)...]) {
            return (String(authority[..<colon]), port)
        }
        return (authority, defaultPort)
    }

    static func resolveURL(head: HTTPRequestHead, scheme: String, interceptedHost: String?) -> (String, String) {
        // Plain proxy requests use an absolute-form URI already.
        if head.uri.lowercased().hasPrefix("http://") || head.uri.lowercased().hasPrefix("https://") {
            let host = URL(string: head.uri)?.host ?? (interceptedHost ?? "")
            return (head.uri, host)
        }
        let host = interceptedHost ?? head.headers.first(name: "host") ?? ""
        let path = head.uri.hasPrefix("/") ? head.uri : "/\(head.uri)"
        return ("\(scheme)://\(host)\(path)", host)
    }
}
