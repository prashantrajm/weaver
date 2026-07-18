import XCTest
import NIOSSL
import NIOCore
import AsyncHTTPClient
@testable import WeaverCore

final class HostFilterTests: XCTestCase {
    func testExactMatch() {
        let f = HostFilter(bypass: ["api.example.com"])
        XCTAssertTrue(f.shouldBypass("api.example.com"))
        XCTAssertFalse(f.shouldBypass("example.com"))
        XCTAssertFalse(f.shouldBypass("other.com"))
    }

    func testWildcardMatchesSubdomainsAndApex() {
        let f = HostFilter(bypass: ["*.example.com"])
        XCTAssertTrue(f.shouldBypass("a.example.com"))
        XCTAssertTrue(f.shouldBypass("deep.a.example.com"))
        XCTAssertTrue(f.shouldBypass("example.com"))
        XCTAssertFalse(f.shouldBypass("notexample.com"))
        XCTAssertFalse(f.shouldBypass("example.com.evil.com"))
    }

    func testAddRemoveIsCaseInsensitiveAndDeduped() {
        let f = HostFilter()
        f.addBypass("API.Example.com")
        f.addBypass("api.example.com")
        XCTAssertEqual(f.bypassPatterns, ["api.example.com"])
        XCTAssertTrue(f.shouldBypass("api.example.com"))
        f.removeBypass("api.example.com")
        XCTAssertFalse(f.shouldBypass("api.example.com"))
    }
}

/// A bypassed host must tunnel the origin's *real* TLS through untouched — so a
/// client that trusts the real cert (but NOT our CA) still succeeds, and the
/// flow is recorded as bypassed. This is the inverse of the pinning test.
final class BypassE2ETests: XCTestCase {
    final class Recorder: ProxyEventHandler, @unchecked Sendable {
        let lock = NSLock()
        var flows: [Flow] = []
        let expectation: XCTestExpectation
        init(_ e: XCTestExpectation) { expectation = e }
        func flowDidStart(_ flow: Flow) { lock.lock(); flows.append(flow); lock.unlock(); expectation.fulfill() }
        func flowDidComplete(_ flow: Flow) {}
        func proxyDidLog(_ message: String) {}
        func snapshot() -> [Flow] { lock.lock(); defer { lock.unlock() }; return flows }
    }

    func testBypassTunnelsRealTLS() async throws {
        let ca = try CertificateAuthority.generate()
        let started = expectation(description: "bypass flow started")
        started.assertForOverFulfill = false
        let recorder = Recorder(started)

        let filter = HostFilter(bypass: ["example.com"])
        let port = Int.random(in: 20000...40000)
        let server = ProxyServer(host: "127.0.0.1", port: port, ca: ca, events: recorder, filter: filter)
        try server.start()
        defer { server.shutdown() }

        // Client trusts the system roots only (the real example.com cert), NOT
        // our CA. It would fail if we intercepted; with bypass it must succeed.
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .fullVerification
        var config = HTTPClient.Configuration(tlsConfiguration: tls)
        config.proxy = .server(host: "127.0.0.1", port: port)
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: config)
        addTeardownBlock { try? client.syncShutdown() }

        let response = try await client.get(url: "https://example.com/").get()
        XCTAssertEqual(response.status, .ok, "real TLS should pass through untouched")

        await fulfillment(of: [started], timeout: 20)
        let bypassed = recorder.snapshot().first { $0.bypassed }
        XCTAssertNotNil(bypassed)
        XCTAssertEqual(bypassed?.host, "example.com")
    }
}
