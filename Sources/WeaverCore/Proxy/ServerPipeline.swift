import Foundation
import NIO
import NIOHTTP1
import NIOHTTP2
import AsyncHTTPClient

/// Configures the client-facing pipeline *after* TLS termination, branching on
/// the negotiated ALPN protocol: an HTTP/2 connection is demultiplexed into
/// streams (each converted to HTTP/1 request/response parts so the existing
/// capture handler is reused), while HTTP/1.1 uses the plain codec.
enum ServerPipeline {

    static func configureAfterTLS(
        channel: Channel,
        host: String,
        port: Int,
        ca: CertificateAuthority,
        events: ProxyEventHandler?,
        httpClient: HTTPClient
    ) -> EventLoopFuture<Void> {
        channel.configureHTTP2SecureUpgrade(
            h2ChannelConfigurator: { h2Channel in
                h2Channel.configureHTTP2Pipeline(mode: .server) { streamChannel in
                    streamChannel.pipeline.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()).flatMap {
                        streamChannel.pipeline.addHandler(
                            ProxyConnectionHandler(
                                ca: ca, events: events, httpClient: httpClient,
                                interceptedHost: host, interceptedPort: port,
                                httpVersionLabel: "HTTP/2"
                            )
                        )
                    }
                }.map { _ in }
            },
            http1ChannelConfigurator: { h1Channel in
                configureHTTP1(channel: h1Channel, host: host, port: port,
                               ca: ca, events: events, httpClient: httpClient)
            }
        )
    }

    static func configureHTTP1(
        channel: Channel,
        host: String,
        port: Int,
        ca: CertificateAuthority,
        events: ProxyEventHandler?,
        httpClient: HTTPClient
    ) -> EventLoopFuture<Void> {
        do {
            let sync = channel.pipeline.syncOperations
            try sync.addHandler(
                ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                name: "http-decoder"
            )
            try sync.addHandler(HTTPResponseEncoder(), name: "http-encoder")
            try sync.addHandler(
                ProxyConnectionHandler(
                    ca: ca, events: events, httpClient: httpClient,
                    interceptedHost: host, interceptedPort: port,
                    httpVersionLabel: "HTTP/1.1"
                ),
                name: "proxy-handler"
            )
            return channel.eventLoop.makeSucceededVoidFuture()
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }
}
