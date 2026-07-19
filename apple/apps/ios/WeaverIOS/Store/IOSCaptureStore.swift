#if os(iOS)
import Foundation
import SwiftUI
import WeaverCore
import InspectorKit

/// iOS session store — the `CaptureController` counterpart (same MVVM layer:
/// WeaverCore → store → `InspectorViewModel` → thin views). Owns the CA, the
/// capture backend, and the live flow list, and bridges backend events onto
/// the main actor. The real backend is the NEPacketTunnelProvider extension
/// (iOS-P0/P1); until it lands, `DemoCaptureBackend`
/// feeds sample flows so the inspector UI is fully drivable — the UI labels
/// this honestly.
@MainActor
final class IOSCaptureStore: ObservableObject {

    @Published private(set) var flows: [Flow] = []
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "Not running"
    @Published private(set) var trustStatus: TrustEvaluator.Status = .unknown
    @Published var isRecording = true
    @Published var blockHTTP3 = HTTP3Policy.blockHTTP3.value {
        didSet { HTTP3Policy.blockHTTP3.value = blockHTTP3 }
    }

    // Hosts to tunnel without decryption (pinned/noisy). Shared with the backend.
    let hostFilter = HostFilter()
    @Published private(set) var bypassList: [String] = []

    /// Result of the last on-device self-test (real request through the proxy).
    @Published var selfTestState: SelfTestState = .idle
    enum SelfTestState: Equatable {
        case idle
        case running
        case passed(status: Int)
        case failed(String)
    }

    // Loopback listener the device's Wi-Fi proxy points at.
    let listenHost = "127.0.0.1"
    let listenPort = 9090
    /// What the user enters as the HTTP proxy in iOS Wi-Fi settings.
    var proxyAddress: String { "\(listenHost):\(listenPort)" }

    private var caManager: CAManager?
    private var backend: CaptureBackend?
    private var eventBridge: EventBridge?

    var authority: CertificateAuthority? { caManager?.authority }
    var certificatePEMURL: URL? { caManager?.certificatePEMURL }

    /// Loads (or generates) the CA off the main thread. Keychain access can
    /// block on a system prompt, so this must not run during view init.
    func bootstrap() async {
        guard caManager == nil else { return }
        statusMessage = "Preparing certificate authority…"
        let result: Result<CAManager, Error> = await Task.detached(priority: .userInitiated) {
            do { return .success(try CAManager()) } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let manager):
            self.caManager = manager
            self.statusMessage = "Ready"
            self.refreshTrustStatus()
        case .failure(let error):
            self.statusMessage = "CA init failed: \(error)"
        }
    }

    func start() {
        guard backend == nil else { return }
        guard let authority = caManager?.authority else {
            statusMessage = "Still preparing CA…"
            return
        }
        let bridge = EventBridge(store: self)
        let backend = LocalProxyBackend(authority: authority, filter: hostFilter,
                                        host: listenHost, port: listenPort)
        do {
            try backend.start(events: bridge)
            self.eventBridge = bridge
            self.backend = backend
            self.isRunning = true
            self.statusMessage = "Proxy on \(proxyAddress) — set your Wi-Fi proxy to capture"
        } catch {
            self.statusMessage = "Couldn't start proxy: \(error)"
        }
    }

    func stop() {
        backend?.stop()
        backend = nil
        eventBridge = nil
        isRunning = false
        statusMessage = "Stopped"
    }

    func toggleRun() { isRunning ? stop() : start() }

    func clear() { flows.removeAll() }

    /// Clear only the requests for one domain (keeps everything else).
    func clearDomain(_ host: String) {
        flows.removeAll { $0.host == host }
    }

    // MARK: - Bypass list

    func addBypass(_ pattern: String) {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        hostFilter.addBypass(p)
        bypassList = hostFilter.bypassPatterns
    }

    func removeBypass(_ pattern: String) {
        hostFilter.removeBypass(pattern)
        bypassList = hostFilter.bypassPatterns
    }

    // MARK: - Certificate trust

    /// Re-evaluate whether the OS actually trusts our CA for TLS — a *verified*
    /// check (mint a test leaf, ask SecTrust), not "the user tapped Install".
    /// The Full Trust toggle silently failing is the category's top footgun.
    func refreshTrustStatus() {
        guard let authority = caManager?.authority else { return }
        Task.detached(priority: .userInitiated) {
            let status = TrustEvaluator.evaluate(authority: authority)
            await MainActor.run { self.trustStatus = status }
        }
    }

    /// A ready-to-install configuration profile carrying the CA certificate,
    /// written to a temp file for the share sheet / Files app.
    func mobileConfigURL() -> URL? {
        guard let authority = caManager?.authority else { return nil }
        do {
            let data = try MobileConfig.profileData(for: authority)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Weaver-CA.mobileconfig")
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            statusMessage = "Profile export failed: \(error)"
            return nil
        }
    }

    // MARK: - Self-test (prove real capture end-to-end on-device)

    /// Fire one real HTTPS request through the running proxy. It appears in the
    /// capture list as a genuine, decrypted flow — proving the whole pipeline
    /// works on this device without first configuring the Wi-Fi proxy or
    /// trusting the CA. Auto-starts the proxy if it isn't running.
    func runSelfTest() {
        guard let authority = caManager?.authority else {
            selfTestState = .failed("CA not ready")
            return
        }
        if backend == nil { start() }
        guard backend != nil else {
            selfTestState = .failed(statusMessage)
            return
        }
        selfTestState = .running
        let port = listenPort
        Task {
            do {
                let status = try await ProxySelfTest.run(through: port, ca: authority)
                self.selfTestState = .passed(status: status)
                self.statusMessage = "Self-test passed — real flow captured (HTTP \(status))"
            } catch {
                self.selfTestState = .failed(String(describing: error))
                self.statusMessage = "Self-test failed: \(error)"
            }
        }
    }

    /// Captured session as a HAR file on disk, for the share sheet.
    func harExportURL() -> URL? {
        let har = HARDocument.buildHAR(flows: flows)
        guard let data = try? JSONSerialization.data(withJSONObject: har, options: [.prettyPrinted]) else {
            return nil
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Weaver-Session.har")
        try? data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Event ingestion (called from EventBridge on the main actor)

    fileprivate func ingestStart(_ flow: Flow) {
        guard isRecording else { return }
        flows.append(flow)
    }

    fileprivate func ingestComplete(_ flow: Flow) {
        // Reference type already mutated in place; nudge SwiftUI to re-render.
        objectWillChange.send()
    }

    fileprivate func ingestUpdate(_ flow: Flow) {
        objectWillChange.send()
    }

    fileprivate func ingestLog(_ message: String) {
        statusMessage = message
    }
}

/// Where captured flows come from. `LocalProxyBackend` (the in-app proxy) is the
/// real backend today; the NEPacketTunnelProvider extension — automatic,
/// backgrounded, zero-config capture — plugs in behind this same seam next.
@MainActor
protocol CaptureBackend: AnyObject {
    var listenAddress: String { get }
    func start(events: ProxyEventHandler) throws
    func stop()
}

/// Forwards backend callbacks (which may arrive off-main) to the main actor.
private final class EventBridge: ProxyEventHandler, @unchecked Sendable {
    private weak var store: IOSCaptureStore?
    init(store: IOSCaptureStore) { self.store = store }

    func flowDidStart(_ flow: Flow) {
        Task { @MainActor in self.store?.ingestStart(flow) }
    }
    func flowDidComplete(_ flow: Flow) {
        Task { @MainActor in self.store?.ingestComplete(flow) }
    }
    func flowDidUpdate(_ flow: Flow) {
        Task { @MainActor in self.store?.ingestUpdate(flow) }
    }
    func proxyDidLog(_ message: String) {
        Task { @MainActor in self.store?.ingestLog(message) }
    }
}
#endif
