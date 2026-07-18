import XCTest
import NIOHTTP1
import NIOSSL
import AsyncHTTPClient
@testable import WeaverCore

final class HTTP3PolicyUnitTests: XCTestCase {
    func testDetectsAndStripsH3() {
        var headers = HTTPHeaders()
        headers.add(name: "Alt-Svc", value: "h3=\":443\"; ma=86400, h3-29=\":443\"; ma=86400, h2=\":443\"")
        XCTAssertTrue(HTTP3Policy.advertisesHTTP3(headers))

        let stripped = HTTP3Policy.stripHTTP3AltSvc(headers)
        let remaining = stripped[canonicalForm: "alt-svc"].map(String.init)
        XCTAssertFalse(remaining.contains { $0.lowercased().hasPrefix("h3") })
        XCTAssertTrue(remaining.contains { $0.hasPrefix("h2=") }, "non-h3 alternatives are preserved")
    }

    func testDropsHeaderWhenOnlyH3() {
        var headers = HTTPHeaders()
        headers.add(name: "Alt-Svc", value: "h3=\":443\"; ma=2592000")
        let stripped = HTTP3Policy.stripHTTP3AltSvc(headers)
        XCTAssertFalse(stripped.contains(name: "alt-svc"))
    }

    func testPreservesClearDirective() {
        var headers = HTTPHeaders()
        headers.add(name: "Alt-Svc", value: "clear")
        let stripped = HTTP3Policy.stripHTTP3AltSvc(headers)
        XCTAssertEqual(stripped.first(name: "alt-svc"), "clear")
    }
}

/// A real server that advertises HTTP/3 should be flagged, and the client should
/// receive a response with the h3 Alt-Svc stripped (kept on TCP).
final class HTTP3PolicyE2ETests: XCTestCase {
    final class Recorder: ProxyEventHandler, @unchecked Sendable {
        let lock = NSLock()
        var completed: [Flow] = []
        let expectation: XCTestExpectation
        init(_ e: XCTestExpectation) { expectation = e }
        func flowDidStart(_ flow: Flow) {}
        func flowDidComplete(_ flow: Flow) { lock.lock(); completed.append(flow); lock.unlock(); expectation.fulfill() }
        func proxyDidLog(_ message: String) {}
        func snapshot() -> [Flow] { lock.lock(); defer { lock.unlock() }; return completed }
    }

    func testStripsAltSvcH3EndToEnd() async throws {
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
        config.proxy = .server(host: "127.0.0.1", port: port)
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: config)

        let response = try await client.get(url: "https://www.cloudflare.com/").get()
        XCTAssertEqual(response.status, .ok)
        // The client must NOT be told about h3 (so it stays on TCP).
        let altSvc = response.headers[canonicalForm: "alt-svc"].map(String.init)
        XCTAssertFalse(altSvc.contains { $0.lowercased().hasPrefix("h3") }, "h3 Alt-Svc should be stripped: \(altSvc)")

        await fulfillment(of: [done], timeout: 25)
        try await client.shutdown()

        let flow = recorder.snapshot().first { $0.host == "www.cloudflare.com" }
        XCTAssertEqual(flow?.serverAdvertisedHTTP3, true, "server offered h3, flow should be flagged")
    }
}
