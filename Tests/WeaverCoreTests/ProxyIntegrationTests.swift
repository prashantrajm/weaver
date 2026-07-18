import XCTest
import NIOSSL
import NIOCore
import AsyncHTTPClient
@testable import WeaverCore

final class CertificateTests: XCTestCase {
    func testGenerateCAAndMintLeaf() throws {
        let ca = try CertificateAuthority.generate()
        XCTAssertFalse(try ca.certificatePEM().isEmpty)

        let leaf = try ca.leaf(forHost: "example.com")
        // Leaf is issued by the CA subject.
        XCTAssertEqual(leaf.certificate.issuer, ca.certificate.subject)
        // Repeat mint for same host is cached (same serial).
        let again = try ca.leaf(forHost: "example.com")
        XCTAssertEqual(leaf.certificate.serialNumber, again.certificate.serialNumber)
    }

    func testRoundTripSerialization() throws {
        let ca = try CertificateAuthority.generate()
        let certPEM = try ca.certificatePEM()
        let keyPEM = try ca.privateKeyPEM()
        let reloaded = try CertificateAuthority.load(certificatePEM: certPEM, privateKeyPEM: keyPEM)
        XCTAssertEqual(reloaded.certificate.subject, ca.certificate.subject)
    }
}

/// End-to-end MITM: a client that trusts our CA fetches a real HTTPS site
/// through the proxy, and we should capture the decrypted exchange.
final class ProxyIntegrationTests: XCTestCase {

    final class Recorder: ProxyEventHandler, @unchecked Sendable {
        let lock = NSLock()
        var completed: [Flow] = []
        let expectation: XCTestExpectation
        init(_ expectation: XCTestExpectation) { self.expectation = expectation }
        func flowDidStart(_ flow: Flow) {}
        func flowDidComplete(_ flow: Flow) {
            lock.lock(); completed.append(flow); lock.unlock()
            expectation.fulfill()
        }
        func proxyDidLog(_ message: String) {}
        func snapshot() -> [Flow] { lock.lock(); defer { lock.unlock() }; return completed }
    }

    func testDecryptsHTTPSThroughProxy() async throws {
        let ca = try CertificateAuthority.generate()
        let done = expectation(description: "flow captured")
        let recorder = Recorder(done)

        let port = Int.random(in: 20000...40000)
        let server = ProxyServer(host: "127.0.0.1", port: port, ca: ca, events: recorder)
        try server.start()
        defer { server.shutdown() }

        // Client trusts OUR CA and routes through the proxy.
        let caCert = try NIOSSLCertificate(bytes: Array(try ca.certificatePEM().utf8), format: .pem)
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.trustRoots = .certificates([caCert])

        var config = HTTPClient.Configuration(tlsConfiguration: tls)
        config.proxy = .server(host: "127.0.0.1", port: port)
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: config)

        let response = try await client.get(url: "https://example.com/").get()
        XCTAssertEqual(response.status, .ok)

        await fulfillment(of: [done], timeout: 20)
        try await client.shutdown()
        let flows = recorder.snapshot()
        XCTAssertTrue(flows.contains { $0.host == "example.com" && $0.isTLS && $0.statusCode == 200 })
    }
}
