#if os(iOS)
import Foundation
import NetworkExtension
import Combine

/// App-side control of the packet-tunnel VPN. Installs the VPN configuration
/// (the profile the user approves once), starts/stops it, and publishes live
/// status — so the app can offer the one-button "turn on capture" flow instead
/// of manual Wi-Fi proxy setup. The capture itself runs in the
/// `PacketTunnelProvider` extension; this just drives its lifecycle.
@MainActor
final class TunnelController: ObservableObject {
    static let providerBundleID = "com.weaver.ios.tunnel"

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var lastError: String?

    private var manager: NETunnelProviderManager?
    nonisolated(unsafe) private var statusObserver: NSObjectProtocol?

    var isActive: Bool { status == .connected || status == .connecting || status == .reasserting }

    init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] note in
            // Delivered on the main queue; read the Sendable status synchronously
            // so the non-Sendable connection never crosses an isolation boundary.
            guard let status = (note.object as? NEVPNConnection)?.status else { return }
            Task { @MainActor in self?.status = status }
        }
    }

    deinit {
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
    }

    /// Load an existing saved VPN configuration, if the user installed one before.
    func refresh() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            self.manager = managers.first
            self.status = manager?.connection.status ?? .invalid
        } catch {
            self.lastError = "Load failed: \(error.localizedDescription)"
        }
    }

    /// Create + save the VPN configuration if needed. The first save prompts the
    /// user to allow the VPN profile (system dialog + Face ID / passcode).
    @discardableResult
    func install() async -> Bool {
        let manager = self.manager ?? NETunnelProviderManager()
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.providerBundleID
        // Required by NE even for on-device tunnels; not a real server.
        proto.serverAddress = "Weaver (on-device)"
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Weaver Capture"
        manager.isEnabled = true
        do {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()   // re-load so it's usable now
            self.manager = manager
            self.status = manager.connection.status
            self.lastError = nil
            return true
        } catch {
            self.lastError = "Install failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Install (if needed) and start the tunnel.
    func start() async {
        if manager == nil { guard await install() else { return } }
        do {
            try manager?.connection.startVPNTunnel()
            self.lastError = nil
        } catch {
            self.lastError = "Start failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
    }
}
#endif
