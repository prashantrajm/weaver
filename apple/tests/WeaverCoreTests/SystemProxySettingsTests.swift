import XCTest
@testable import WeaverCore

final class SystemProxySettingsTests: XCTestCase {
    typealias Key = SystemProxySettings.Key

    func testAppliesHTTPAndHTTPSAndKeepsOtherKeys() {
        let current: [String: Any] = [
            "SOCKSEnable": 1, "SOCKSProxy": "socks.example", "SOCKSPort": 1080,
            "ExcludeSimpleHostnames": 1,
            Key.exceptionsList: ["*.corp.example", "*.local"],
        ]
        let applied = SystemProxySettings.applying(host: "127.0.0.1", port: 9090, to: current)

        XCTAssertEqual(applied[Key.httpEnable] as? Int, 1)
        XCTAssertEqual(applied[Key.httpProxy] as? String, "127.0.0.1")
        XCTAssertEqual(applied[Key.httpPort] as? Int, 9090)
        XCTAssertEqual(applied[Key.httpsEnable] as? Int, 1)
        XCTAssertEqual(applied[Key.httpsProxy] as? String, "127.0.0.1")
        XCTAssertEqual(applied[Key.httpsPort] as? Int, 9090)

        // Untouched keys survive so a restore is exact.
        XCTAssertEqual(applied["SOCKSProxy"] as? String, "socks.example")
        XCTAssertEqual(applied["ExcludeSimpleHostnames"] as? Int, 1)

        // User exceptions kept, required ones merged without duplicates.
        let exceptions = applied[Key.exceptionsList] as? [String] ?? []
        XCTAssertEqual(exceptions.first, "*.corp.example")
        XCTAssertEqual(exceptions.filter { $0 == "*.local" }.count, 1)
        for required in SystemProxySettings.requiredExceptions {
            XCTAssertTrue(exceptions.contains(required), "missing \(required)")
        }
    }

    func testAppliesToEmptyConfiguration() {
        let applied = SystemProxySettings.applying(host: "127.0.0.1", port: 9090, to: [:])
        XCTAssertEqual(applied[Key.httpsPort] as? Int, 9090)
        XCTAssertEqual(applied[Key.exceptionsList] as? [String], SystemProxySettings.requiredExceptions)
    }

    func testPointsAtDetectsOurConfigOnly() {
        let ours = SystemProxySettings.applying(host: "127.0.0.1", port: 9090, to: [:])
        XCTAssertTrue(SystemProxySettings.pointsAt(host: "127.0.0.1", port: 9090, in: ours))
        XCTAssertFalse(SystemProxySettings.pointsAt(host: "127.0.0.1", port: 9091, in: ours))

        // Same address but disabled (what networksetup leaves behind) is not "ours".
        var disabled = ours
        disabled[Key.httpEnable] = 0
        disabled[Key.httpsEnable] = 0
        XCTAssertFalse(SystemProxySettings.pointsAt(host: "127.0.0.1", port: 9090, in: disabled))

        XCTAssertFalse(SystemProxySettings.pointsAt(host: "127.0.0.1", port: 9090, in: [:]))
    }

    func testPointsAtAcceptsNSNumberValuesFromSystemConfiguration() {
        // SC hands back CFNumbers, which bridge to NSNumber not Int.
        let live: [String: Any] = [
            Key.httpsEnable: NSNumber(value: 1),
            Key.httpsProxy: "127.0.0.1",
            Key.httpsPort: NSNumber(value: 9090),
        ]
        XCTAssertTrue(SystemProxySettings.pointsAt(host: "127.0.0.1", port: 9090, in: live))
    }
}
