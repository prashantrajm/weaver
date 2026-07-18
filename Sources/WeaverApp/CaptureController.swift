import Foundation
import SwiftUI
import WeaverCore

/// Owns the CA, the proxy, and the live capture state. Bridges proxy events
/// (delivered on NIO threads) onto the main actor for the SwiftUI inspector.
@MainActor
final class CaptureController: ObservableObject {

    @Published private(set) var flows: [Flow] = []
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "Not running"
    @Published private(set) var trustState: CAManager.TrustState = .notInstalled
    @Published var isRecording = true
    @Published var blockHTTP3 = HTTP3Policy.blockHTTP3.value {
        didSet { HTTP3Policy.blockHTTP3.value = blockHTTP3 }
    }

    // Throughput (bytes since last sample).
    @Published private(set) var bytesIn = 0
    @Published private(set) var bytesOut = 0

    // Bind all interfaces so a device on the same Wi-Fi can reach the proxy;
    // `lanAddress` is what the user enters as the HTTP proxy on that device.
    let listenHost = "0.0.0.0"
    let listenPort = 9090
    @Published private(set) var lanAddress: String?

    /// The address to point a device at: the LAN IP if known, else loopback.
    var deviceProxyHost: String { lanAddress ?? "127.0.0.1" }

    // Hosts to tunnel without decryption (pinned/noisy). Shared with the proxy.
    let hostFilter = HostFilter()
    @Published private(set) var bypassList: [String] = []

    private var caManager: CAManager?
    private var server: ProxyServer?
    private var eventBridge: EventBridge?

    var caCertificatePath: String { caManager?.certificatePEMURL.path ?? "" }

    init() {}

    /// Loads (or generates) the CA off the main thread. Keychain access can
    /// block on a system prompt, so this must not run during view/window init.
    func bootstrap() async {
        guard caManager == nil else { return }
        lanAddress = LocalAddress.primaryIPv4()
        statusMessage = "Preparing certificate authority…"
        let result: Result<(CAManager, CAManager.TrustState), Error> = await Task.detached(priority: .userInitiated) {
            do {
                let manager = try CAManager()
                return .success((manager, manager.trustState()))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let (manager, trust)):
            self.caManager = manager
            self.trustState = trust
            self.statusMessage = "Ready — press Start"
        case .failure(let error):
            self.statusMessage = "CA init failed: \(error)"
        }
    }

    func start() {
        guard let caManager, server == nil else {
            if caManager == nil { statusMessage = "Still preparing CA…" }
            return
        }
        let bridge = EventBridge(controller: self)
        self.eventBridge = bridge
        self.lanAddress = LocalAddress.primaryIPv4()
        let server = ProxyServer(host: listenHost, port: listenPort,
                                 ca: caManager.authority, events: bridge, filter: hostFilter)
        do {
            try server.start()
            self.server = server
            self.isRunning = true
            self.statusMessage = "Listening on \(deviceProxyHost):\(listenPort)"
        } catch {
            self.statusMessage = "Start failed: \(error)"
        }
    }

    func stop() {
        server?.shutdown()
        server = nil
        eventBridge = nil
        isRunning = false
        statusMessage = "Stopped"
    }

    func toggleRun() { isRunning ? stop() : start() }

    func clear() {
        flows.removeAll()
        bytesIn = 0
        bytesOut = 0
    }

    /// Clear only the requests from one app group (keeps everything else) — so a
    /// chatty app doesn't bury the endpoint you're hunting for.
    func clearApp(_ name: String) {
        flows.removeAll { $0.appDisplayName == name }
    }

    /// Clear only the requests for one domain.
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

    // MARK: - Trust management

    func installAndTrustCA() {
        guard let caManager else { return }
        DispatchQueue.global().async {
            let ok = (try? caManager.installAndTrust()) ?? false
            let state = caManager.trustState()
            Task { @MainActor in
                self.trustState = state
                self.statusMessage = ok ? "CA installed & trusted" : "CA install cancelled/failed"
            }
        }
    }

    func refreshTrustState() {
        guard let caManager else { return }
        DispatchQueue.global().async {
            let state = caManager.trustState()
            Task { @MainActor in self.trustState = state }
        }
    }

    func revealCACertificate() {
        guard let caManager else { return }
        NSWorkspace.shared.activateFileViewerSelecting([caManager.certificatePEMURL])
    }

    // MARK: - Event ingestion (called from EventBridge on the main actor)

    fileprivate func ingestStart(_ flow: Flow) {
        guard isRecording else { return }
        flows.append(flow)
        bytesOut += flow.requestSize
    }

    fileprivate func ingestComplete(_ flow: Flow) {
        bytesIn += flow.responseSize
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

/// Forwards proxy callbacks (arriving on NIO threads) to the main actor.
private final class EventBridge: ProxyEventHandler, @unchecked Sendable {
    private weak var controller: CaptureController?
    init(controller: CaptureController) { self.controller = controller }

    func flowDidStart(_ flow: Flow) {
        Task { @MainActor in controller?.ingestStart(flow) }
    }
    func flowDidComplete(_ flow: Flow) {
        Task { @MainActor in controller?.ingestComplete(flow) }
    }
    func flowDidUpdate(_ flow: Flow) {
        Task { @MainActor in controller?.ingestUpdate(flow) }
    }
    func proxyDidLog(_ message: String) {
        Task { @MainActor in controller?.ingestLog(message) }
    }
}
