import XCTest
import NIOSSL
import NIOCore
import AsyncHTTPClient
@testable import WeaverCore

/// The proxy must be reachable from another device on the LAN, i.e. bound to a
/// non-loopback interface — not just 127.0.0.1.
final class LanBindingTests: XCTestCase {

    func testDiscoversNonLoopbackIPv4() throws {
        guard let ip = LocalAddress.primaryIPv4() else {
            throw XCTSkip("no LAN interface on this host")
        }
        XCTAssertFalse(ip.hasPrefix("127."), "should not be loopback")
        XCTAssertFalse(ip.hasPrefix("169.254."), "should not be link-local")
        XCTAssertTrue(ip.contains("."), "should be an IPv4 dotted quad: \(ip)")
    }

    final class Recorder: ProxyEventHandler, @unchecked Sendable {
        let expectation: XCTestExpectation
        init(_ e: XCTestExpectation) { expectation = e }
        func flowDidStart(_ flow: Flow) {}
        func flowDidComplete(_ flow: Flow) { expectation.fulfill() }
        func proxyDidLog(_ message: String) {}
    }

    func testReachableViaLANAddress() async throws {
        guard let lanIP = LocalAddress.primaryIPv4() else {
            throw XCTSkip("no LAN interface on this host")
        }

        let ca = try CertificateAuthority.generate()
        let done = expectation(description: "flow captured")
        let recorder = Recorder(done)

        let port = Int.random(in: 20000...40000)
        // Bind all interfaces, exactly as the app does.
        let server = ProxyServer(host: "0.0.0.0", port: port, ca: ca, events: recorder)
        try server.start()
        defer { server.shutdown() }

        let caCert = try NIOSSLCertificate(bytes: Array(try ca.certificatePEM().utf8), format: .pem)
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.trustRoots = .certificates([caCert])
        var config = HTTPClient.Configuration(tlsConfiguration: tls)
        // Reach the proxy through its LAN IP, NOT loopback.
        config.proxy = .server(host: lanIP, port: port)
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: config)

        let response = try await client.get(url: "https://example.com/").get()
        XCTAssertEqual(response.status, .ok)

        await fulfillment(of: [done], timeout: 20)
        try await client.shutdown()
    }
}
