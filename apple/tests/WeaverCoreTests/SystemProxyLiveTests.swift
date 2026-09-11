#if os(macOS)
import XCTest
import SystemConfiguration
@testable import WeaverCore

/// Opt-in end-to-end check of the real SystemConfiguration path. It changes
/// the Mac's system proxy (and puts it back), and shows one admin prompt, so
/// it only runs with `WEAVER_LIVE_SYSPROXY=1 swift test --filter SystemProxyLiveTests`.
final class SystemProxyLiveTests: XCTestCase {
    func testEnableThenRestoreRoundTrips() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WEAVER_LIVE_SYSPROXY"] == "1",
                          "set WEAVER_LIVE_SYSPROXY=1 to run (changes system proxy, prompts for admin)")
        let host = "127.0.0.1", port = 9090
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("weaver-live-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let configurator = SystemProxyConfigurator(snapshotDirectory: dir)
        let before = SCDynamicStoreCopyProxies(nil) as? [String: Any] ?? [:]
        XCTAssertFalse(SystemProxySettings.pointsAt(host: host, port: port, in: before), "precondition: not already set")

        let services = try configurator.enable(host: host, port: port)
        XCTAssertFalse(services.isEmpty)
        XCTAssertTrue(configurator.hasSnapshot)
        // configd applies asynchronously; poll the live store briefly.
        XCTAssertTrue(waitUntil { SystemProxyConfigurator.currentSystemProxyPointsAt(host: host, port: port) },
                      "live proxy should point at Weaver after enable")

        try configurator.restore()
        XCTAssertFalse(configurator.hasSnapshot)
        XCTAssertTrue(waitUntil { !SystemProxyConfigurator.currentSystemProxyPointsAt(host: host, port: port) },
                      "live proxy should be back to the original after restore")
        let after = SCDynamicStoreCopyProxies(nil) as? [String: Any] ?? [:]
        for key in [SystemProxySettings.Key.httpEnable, SystemProxySettings.Key.httpsEnable] {
            XCTAssertEqual((after[key] as? NSNumber)?.intValue ?? 0, (before[key] as? NSNumber)?.intValue ?? 0, key)
        }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }
}
#endif
