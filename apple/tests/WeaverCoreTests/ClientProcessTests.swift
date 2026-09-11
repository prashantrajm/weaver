import XCTest
import NIO
@testable import WeaverCore

final class ConnectionEventTaggerTests: XCTestCase {
    private final class Recorder: ProxyEventHandler, @unchecked Sendable {
        var started: [Flow] = []
        var updated: [Flow] = []
        func flowDidStart(_ flow: Flow) { started.append(flow) }
        func flowDidComplete(_ flow: Flow) {}
        func flowDidUpdate(_ flow: Flow) { updated.append(flow) }
        func proxyDidLog(_ message: String) {}
    }

    private func makeFlow() -> Flow {
        Flow(method: "GET", url: URL(string: "http://example.com/")!, scheme: "http",
             host: "example.com", path: "/", isTLS: false, clientDescription: "curl/8.0")
    }

    func testFlowStartedBeforeResolutionIsPatchedAndUpdated() {
        let recorder = Recorder()
        let tagger = ConnectionEventTagger(upstream: recorder)
        let early = makeFlow()
        tagger.flowDidStart(early)
        XCTAssertNil(early.clientProcess)
        XCTAssertEqual(recorder.started.count, 1)

        let process = ClientProcess(pid: 42, name: "Safari")
        tagger.resolved(process)
        XCTAssertEqual(early.clientProcess, process)
        XCTAssertEqual(recorder.updated.map(\.id), [early.id], "UI must be told to regroup")

        let late = makeFlow()
        tagger.flowDidStart(late)
        XCTAssertEqual(late.clientProcess, process, "flows after resolution are stamped immediately")
        XCTAssertEqual(recorder.updated.count, 1, "no extra update for already-stamped flows")
    }

    func testUnresolvedLeavesUserAgentFallback() {
        let recorder = Recorder()
        let tagger = ConnectionEventTagger(upstream: recorder)
        let flow = makeFlow()
        tagger.flowDidStart(flow)
        tagger.resolved(nil)
        XCTAssertNil(flow.clientProcess)
        XCTAssertTrue(recorder.updated.isEmpty)
        tagger.resolved(ClientProcess(pid: 1, name: "late"))
        XCTAssertNil(flow.clientProcess, "first answer wins")
    }

    func testLoopbackDetection() throws {
        XCTAssertTrue(ProxyServer.isLoopback(try SocketAddress(ipAddress: "127.0.0.1", port: 1)))
        XCTAssertTrue(ProxyServer.isLoopback(try SocketAddress(ipAddress: "::1", port: 1)))
        XCTAssertFalse(ProxyServer.isLoopback(try SocketAddress(ipAddress: "192.168.1.20", port: 1)))
    }
}

#if os(macOS)
final class LocalProcessResolverTests: XCTestCase {
    func testEnclosingAppBundle() {
        XCTAssertEqual(LocalProcessResolver.enclosingAppBundle(of: "/Applications/Safari.app/Contents/MacOS/Safari"),
                       "/Applications/Safari.app")
        XCTAssertEqual(LocalProcessResolver.enclosingAppBundle(
            of: "/Applications/Foo.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"),
            "/Applications/Foo.app", "outermost bundle wins")
        XCTAssertNil(LocalProcessResolver.enclosingAppBundle(of: "/usr/bin/curl"))
    }

    func testSystemHelperDetection() {
        XCTAssertTrue(LocalProcessResolver.isSystemHelper(
            "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking"))
        XCTAssertFalse(LocalProcessResolver.isSystemHelper("/usr/bin/curl"), "CLI tools stand on their own")
        XCTAssertFalse(LocalProcessResolver.isSystemHelper(
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"),
            "helpers inside an .app resolve via the outermost bundle instead")
    }

    /// Real end-to-end: connect to a local listener from this process and
    /// resolve the client port back to our own pid.
    func testResolvesOwnConnectionToThisProcess() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let server = try ServerBootstrap(group: group)
            .childChannelInitializer { $0.eventLoop.makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0).wait()
        defer { try? server.close().wait() }
        let proxyPort = server.localAddress!.port!

        let client = try ClientBootstrap(group: group).connect(host: "127.0.0.1", port: proxyPort).wait()
        defer { try? client.close().wait() }
        let clientPort = client.localAddress!.port!

        let resolver = LocalProcessResolver()
        let start = Date()
        let process = resolver.resolveSync(clientPort: clientPort, proxyPort: proxyPort)
        let elapsed = Date().timeIntervalSince(start)

        let me = ProcessInfo.processInfo.processIdentifier
        XCTAssertNotNil(process, "should find the owner of our own socket")
        XCTAssertEqual(process?.pid, me, "got \(String(describing: process))")
        XCTAssertFalse(process?.name.isEmpty ?? true)
        XCTAssertLessThan(elapsed, 0.5, "resolution took \(elapsed)s")

        // Second lookup hits the last-pid fast path and the metadata cache.
        let again = resolver.resolveSync(clientPort: clientPort, proxyPort: proxyPort)
        XCTAssertEqual(again, process)

        // A port nobody owns resolves to nil rather than a wrong process.
        XCTAssertNil(resolver.resolveSync(clientPort: 1, proxyPort: proxyPort))
    }
}
#endif

#if os(macOS)
/// Through the real proxy: `curl` on this Mac → flow attributed to curl by PID.
final class ProcessAttributionIntegrationTests: XCTestCase {
    private final class Collector: ProxyEventHandler, @unchecked Sendable {
        let lock = NSLock()
        var flows: [Flow] = []
        func flowDidStart(_ flow: Flow) { lock.lock(); flows.append(flow); lock.unlock() }
        func flowDidComplete(_ flow: Flow) {}
        func proxyDidLog(_ message: String) {}
        func snapshot() -> [Flow] { lock.lock(); defer { lock.unlock() }; return flows }
    }

    func testCurlIsAttributedByProcess() throws {
        let collector = Collector()
        let port = Int.random(in: 20000..<40000)
        let server = ProxyServer(host: "127.0.0.1", port: port, ca: try CertificateAuthority.generate(),
                                 events: collector, threads: 1, clientResolver: LocalProcessResolver())
        try server.start()
        defer { server.shutdown() }

        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-s", "-o", "/dev/null", "-x", "127.0.0.1:\(port)", "http://example.com/"]
        try curl.run()
        curl.waitUntilExit()

        let deadline = Date().addingTimeInterval(5)
        var flow: Flow?
        while Date() < deadline {
            flow = collector.snapshot().first
            if flow?.clientProcess != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let process = try XCTUnwrap(flow?.clientProcess, "flow should carry the originating process")
        XCTAssertEqual(process.name, "curl")
    }
}
#endif
