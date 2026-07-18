import XCTest
import NIOCore
import NIOEmbedded
import NIOHTTP1
import AsyncHTTPClient
@testable import WeaverCore

final class ConnectParsingTests: XCTestCase {
    func testIndexAfterDoubleCRLF() {
        let bytes = Array("CONNECT example.com:443 HTTP/1.1\r\nHost: x\r\n\r\nEXTRA".utf8)
        let idx = ConnectSniffer.indexAfterDoubleCRLF(bytes)
        XCTAssertNotNil(idx)
        // Everything after the header must be preserved exactly.
        XCTAssertEqual(String(decoding: bytes[idx!...], as: UTF8.self), "EXTRA")
    }

    func testFirstLine() {
        let bytes = Array("CONNECT api.onesignal.com:443 HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
        XCTAssertEqual(ConnectSniffer.firstLine(bytes), "CONNECT api.onesignal.com:443 HTTP/1.1")
    }

    func testNoDoubleCRLFYet() {
        XCTAssertNil(ConnectSniffer.indexAfterDoubleCRLF(Array("CONNECT x:443 HTTP/1.1\r\n".utf8)))
    }
}

/// Reproduces the iOS behaviour that broke real-device capture: the TLS
/// ClientHello arrives in the *same* buffer as the CONNECT line. The sniffer
/// must forward the ClientHello to the TLS handler byte-for-byte; if its first
/// byte were consumed, the TLS record layer would reject it (WRONG_VERSION) and
/// tear the connection down.
final class ConnectHandoffTests: XCTestCase {
    func testPipelinedClientHelloReachesTLSIntact() throws {
        let ca = try CertificateAuthority.generate()
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { try? httpClient.syncShutdown() }

        let channel = EmbeddedChannel()
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 443)).wait()
        let sniffer = ConnectSniffer(ca: ca, events: nil, httpClient: httpClient, filter: HostFilter())
        try channel.pipeline.syncOperations.addHandler(sniffer, name: ConnectSniffer.name)

        // One buffer: CONNECT request head + the start of a valid TLS record
        // (handshake=0x16, TLS 1.2=0x0303, length 0x0050 — body deliberately
        // incomplete so the record layer buffers rather than parses).
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeString("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
        buffer.writeBytes([0x16, 0x03, 0x03, 0x00, 0x50, 0x01, 0x00])

        try channel.writeInbound(buffer)
        channel.embeddedEventLoop.run()   // let the async pipeline reconfig complete

        // The tunnel was acknowledged...
        var out = try channel.readOutbound(as: ByteBuffer.self)
        let available = out?.readableBytes ?? 0
        let response = out?.readString(length: available) ?? ""
        XCTAssertTrue(response.contains("200 Connection Established"), "got: \(response)")

        // ...and the connection is still alive: the TLS handler accepted the
        // record header (0x16…) and is waiting for the rest, rather than
        // erroring on an offset byte and closing.
        XCTAssertTrue(channel.isActive, "TLS rejected the ClientHello — first byte was likely consumed")

        _ = try? channel.finish()
    }
}
