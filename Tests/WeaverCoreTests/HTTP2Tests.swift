import XCTest
import NIOSSL
import NIOCore
import AsyncHTTPClient
@testable import WeaverCore

/// The proxy advertises h2 via ALPN; a client that prefers HTTP/2 should
/// negotiate it end-to-end and we should tag the captured flow as HTTP/2.
final class HTTP2Tests: XCTestCase {

    final class Recorder: ProxyEventHandler, @unchecked Sendable {
        let lock = NSLock()
        var completed: [Flow] = []
        let expectation: XCTestExpectation
        init(_ e: XCTestExpectation) { expectation = e }
        func flowDidStart(_ flow: Flow) {}
        func flowDidComplete(_ flow: Flow) {
            lock.lock(); completed.append(flow); lock.unlock()
            expectation.fulfill()
        }
        func proxyDidLog(_ message: String) {}
        func snapshot() -> [Flow] { lock.lock(); defer { lock.unlock() }; return completed }
    }

    func testNegotiatesHTTP2AndTags() async throws {
        let ca = try CertificateAuthority.generate()
        let done = expectation(description: "flow captured")
        let recorder = Recorder(done)

        let port = Int.random(in: 20000...40000)
        let server = ProxyServer(host: "127.0.0.1", port: port, ca: ca, events: recorder)
        try server.start()
        defer { server.shutdown() }

        let caCert = try NIOSSLCertificate(bytes: Array(try ca.certificatePEM().utf8), format: .pem)
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.trustRoots = .certificates([caCert])

        var config = HTTPClient.Configuration(tlsConfiguration: tls)
        config.httpVersion = .automatic       // allow h2 when ALPN offers it
        config.proxy = .server(host: "127.0.0.1", port: port)
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: config)

        // httpbin/nghttp2 support h2; example.com does too.
        let response = try await client.get(url: "https://www.cloudflare.com/").get()
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(response.version.major, 2, "client<->proxy leg should be HTTP/2")

        await fulfillment(of: [done], timeout: 25)
        try await client.shutdown()

        let flows = recorder.snapshot()
        let http2 = flows.first { $0.host == "www.cloudflare.com" }
        XCTAssertNotNil(http2)
        XCTAssertEqual(http2?.httpVersion, "HTTP/2")
    }
}
