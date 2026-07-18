import XCTest
import NIOSSL
import NIOCore
import AsyncHTTPClient
@testable import WeaverCore

/// A client that does not trust our CA rejects the leaf during the handshake —
/// exactly what a pinned app does. The proxy should surface that as a flagged
/// flow rather than closing silently.
final class PinningTests: XCTestCase {

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

    func testSurfacesHandshakeRejectionAsFlow() async throws {
        let ca = try CertificateAuthority.generate()
        let failed = expectation(description: "tls failure flow")
        failed.assertForOverFulfill = false   // retries legitimately emit one flow each
        let recorder = Recorder(failed)

        let port = Int.random(in: 20000...40000)
        let server = ProxyServer(host: "127.0.0.1", port: port, ca: ca, events: recorder)
        try server.start()
        defer { server.shutdown() }

        // Client trusts only the system roots — NOT our CA — so it will reject
        // our minted leaf, just like a pinned app.
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .fullVerification
        var config = HTTPClient.Configuration(tlsConfiguration: tls)
        config.proxy = .server(host: "127.0.0.1", port: port)
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: config)
        addTeardownBlock { try? client.syncShutdown() }

        // The request itself is expected to fail (handshake rejected).
        do {
            _ = try await client.get(url: "https://example.com/").get()
            XCTFail("handshake should have been rejected")
        } catch {
            // expected
        }

        await fulfillment(of: [failed], timeout: 20)

        let flows = recorder.snapshot()
        let pinned = flows.first { $0.tlsInterceptionFailed }
        XCTAssertNotNil(pinned, "should surface a TLS-interception-failed flow")
        XCTAssertEqual(pinned?.host, "example.com")
        XCTAssertTrue(pinned?.error?.contains("pinning") ?? false)
    }
}
