#if os(macOS)
import Foundation
import Security
import SystemConfiguration

/// Points the Mac's own network services at Weaver and puts them back
/// afterwards, so capturing this Mac needs no manual proxy setup.
///
/// Mechanism: `SCPreferencesCreateWithAuthorization` with the
/// `system.services.systemconfiguration.network` right — the same path
/// System Settings › Network uses. It prompts for admin once per process (the
/// `AuthorizationRef` keeps the granted right alive) and needs no helper tool
/// or root shell-out, unlike `networksetup`.
///
/// Safety: before changing anything, the per-service `Proxies` dictionaries
/// are snapshotted to disk. `restore()` replays that snapshot verbatim. If the
/// app dies with the proxy set, the snapshot outlives it and
/// `recoverIfNeeded` on the next launch puts the network back — a stale system
/// proxy with nothing listening would otherwise take the whole Mac offline.
///
/// Not thread-safe: callers serialize access (see `CaptureController`).
public final class SystemProxyConfigurator: @unchecked Sendable {

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case authorizationCancelled
        case authorizationFailed(OSStatus)
        case preferencesUnavailable
        case noConfigurableServices
        case commitFailed(String)

        public var description: String {
            switch self {
            case .authorizationCancelled: return "Admin authorization cancelled"
            case .authorizationFailed(let code): return "Admin authorization failed (\(code))"
            case .preferencesUnavailable: return "Couldn't open network preferences"
            case .noConfigurableServices: return "No active network service to configure"
            case .commitFailed(let why): return "Couldn't apply network settings: \(why)"
            }
        }
    }

    private static let right = "system.services.systemconfiguration.network"

    private let snapshotURL: URL
    private var authorization: AuthorizationRef?

    /// `snapshotDirectory` should be Weaver's Application Support folder.
    public init(snapshotDirectory: URL) {
        self.snapshotURL = snapshotDirectory.appendingPathComponent("system-proxy-snapshot.plist")
    }

    deinit {
        if let authorization { AuthorizationFree(authorization, []) }
    }

    /// A snapshot on disk means a previous run set the proxy and never restored it.
    public var hasSnapshot: Bool { FileManager.default.fileExists(atPath: snapshotURL.path) }

    // MARK: - Public operations

    /// Route this Mac's HTTP/HTTPS through `host:port`. Returns the display
    /// names of the services configured (e.g. "Wi-Fi").
    @discardableResult
    public func enable(host: String, port: Int) throws -> [String] {
        let prefs = try openPreferences()
        let services = try configurableServices(in: prefs)
        guard !services.isEmpty else { throw Failure.noConfigurableServices }

        // Snapshot first, and only the first time: re-enabling on top of our own
        // settings must not overwrite the user's real ones.
        var snapshot = loadSnapshot() ?? [:]
        var names: [String] = []
        for service in services {
            guard let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
            let id = SCNetworkServiceGetServiceID(service) as String? ?? ""
            let current = Self.configuration(of: proto)
            if snapshot[id] == nil, !SystemProxySettings.pointsAt(host: host, port: port, in: current) {
                snapshot[id] = current
            }
            SCNetworkProtocolSetConfiguration(proto, SystemProxySettings.applying(host: host, port: port, to: current) as CFDictionary)
            names.append(SCNetworkServiceGetName(service) as String? ?? id)
        }
        try saveSnapshot(snapshot)
        try commit(prefs)
        return names
    }

    /// Put every service back exactly as it was before `enable`, then discard
    /// the snapshot. No-op when there is nothing to restore.
    public func restore() throws {
        guard let snapshot = loadSnapshot() else { return }
        let prefs = try openPreferences()
        guard let set = SCNetworkSetCopyCurrent(prefs),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else {
            throw Failure.preferencesUnavailable
        }
        for service in services {
            let id = SCNetworkServiceGetServiceID(service) as String? ?? ""
            guard let original = snapshot[id],
                  let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
            SCNetworkProtocolSetConfiguration(proto, original.isEmpty ? nil : original as CFDictionary)
        }
        try commit(prefs)
        try? FileManager.default.removeItem(at: snapshotURL)
    }

    /// Launch-time crash recovery. If a snapshot exists and the system proxy
    /// still points at us (the last run died with it set), restore it. If the
    /// snapshot exists but the proxy no longer points at us, the user already
    /// fixed it by hand — just drop the stale snapshot. Returns true if a
    /// restore was performed.
    @discardableResult
    public func recoverIfNeeded(host: String, port: Int) throws -> Bool {
        guard hasSnapshot else { return false }
        guard Self.currentSystemProxyPointsAt(host: host, port: port) else {
            try? FileManager.default.removeItem(at: snapshotURL)
            return false
        }
        try restore()
        return true
    }

    /// Read-only check of the live (unauthenticated) system proxy state.
    public static func currentSystemProxyPointsAt(host: String, port: Int) -> Bool {
        guard let live = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return false }
        return SystemProxySettings.pointsAt(host: host, port: port, in: live)
    }

    // MARK: - SystemConfiguration plumbing

    private func openPreferences() throws -> SCPreferences {
        let auth = try ensureAuthorization()
        guard let prefs = SCPreferencesCreateWithAuthorization(nil, "Weaver" as CFString, nil, auth) else {
            throw Failure.preferencesUnavailable
        }
        return prefs
    }

    /// Enabled services in the current set that have a real interface (skips
    /// disabled services and virtual entries with no hardware behind them).
    private func configurableServices(in prefs: SCPreferences) throws -> [SCNetworkService] {
        guard let set = SCNetworkSetCopyCurrent(prefs),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else {
            throw Failure.preferencesUnavailable
        }
        return services.filter { service in
            SCNetworkServiceGetEnabled(service) && SCNetworkServiceGetInterface(service) != nil
        }
    }

    private static func configuration(of proto: SCNetworkProtocol) -> [String: Any] {
        (SCNetworkProtocolGetConfiguration(proto) as? [String: Any]) ?? [:]
    }

    private func commit(_ prefs: SCPreferences) throws {
        guard SCPreferencesCommitChanges(prefs) else {
            throw Failure.commitFailed("commit: " + String(cString: SCErrorString(SCError())))
        }
        guard SCPreferencesApplyChanges(prefs) else {
            throw Failure.commitFailed("apply: " + String(cString: SCErrorString(SCError())))
        }
    }

    /// One admin prompt per process: the granted right lives in the
    /// `AuthorizationRef` for as long as we hold it.
    private func ensureAuthorization() throws -> AuthorizationRef {
        if let authorization { return authorization }

        var ref: AuthorizationRef?
        let status = Self.right.withCString { rightName -> OSStatus in
            var item = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPtr in
                var rights = AuthorizationRights(count: 1, items: itemPtr)
                let prompt = "Weaver wants to route this Mac's web traffic through its local proxy so it can be inspected."
                return prompt.withCString { promptName -> OSStatus in
                    let key = kAuthorizationEnvironmentPrompt.withCString { strdup($0)! }
                    defer { free(key) }
                    var envItem = AuthorizationItem(name: key, valueLength: strlen(promptName),
                                                    value: UnsafeMutableRawPointer(mutating: promptName), flags: 0)
                    return withUnsafeMutablePointer(to: &envItem) { envPtr in
                        var environment = AuthorizationEnvironment(count: 1, items: envPtr)
                        return AuthorizationCreate(&rights, &environment,
                                                   [.interactionAllowed, .extendRights, .preAuthorize], &ref)
                    }
                }
            }
        }
        switch status {
        case errAuthorizationSuccess:
            guard let ref else { throw Failure.authorizationFailed(status) }
            authorization = ref
            return ref
        case errAuthorizationCanceled:
            throw Failure.authorizationCancelled
        default:
            throw Failure.authorizationFailed(status)
        }
    }

    // MARK: - Snapshot persistence (plist: the SC dictionaries are plist-native)

    private func loadSnapshot() -> [String: [String: Any]]? {
        guard let data = try? Data(contentsOf: snapshotURL),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        return object as? [String: [String: Any]]
    }

    private func saveSnapshot(_ snapshot: [String: [String: Any]]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: snapshot, format: .xml, options: 0)
        try data.write(to: snapshotURL, options: .atomic)
    }
}
#endif
