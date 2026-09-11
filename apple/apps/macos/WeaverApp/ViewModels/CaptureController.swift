import Foundation
import SwiftUI
import WeaverCore
import InspectorKit

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

    // MARK: This Mac (automatic system proxy)

    /// What the Mac's own system proxy is currently doing.
    enum SystemProxyState: Equatable {
        case off
        case configuring
        /// Services routed through Weaver, e.g. ["Wi-Fi"].
        case on([String])
        case failed(String)
    }

    /// Route this Mac's own traffic through Weaver whenever the proxy runs.
    /// On by default: the Mac that installed Weaver should be captured with
    /// zero setup. Persisted so an explicit opt-out sticks.
    @Published var captureThisMac: Bool = UserDefaults.standard.object(forKey: "captureThisMac") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(captureThisMac, forKey: "captureThisMac")
            guard isRunning else { return }
            captureThisMac ? enableSystemProxy() : disableSystemProxy()
        }
    }
    @Published private(set) var systemProxyState: SystemProxyState = .off

    private var systemProxy: SystemProxyConfigurator?
    /// The configurator isn't thread-safe and the admin prompt blocks, so every
    /// call goes through this one serial queue, off the main actor.
    private let systemProxyQueue = DispatchQueue(label: "com.weaver.system-proxy", qos: .userInitiated)
    private var terminationObserver: NSObjectProtocol?
    private var signalSources: [DispatchSourceSignal] = []

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

        let configurator = SystemProxyConfigurator(snapshotDirectory: Self.supportDirectory())
        self.systemProxy = configurator
        installRestoreOnExit()
        await recoverSystemProxyIfNeeded(configurator)
    }

    private static func supportDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Weaver", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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
            return
        }
        if captureThisMac { enableSystemProxy() }
    }

    func stop() {
        let server = self.server
        self.server = nil
        eventBridge = nil
        isRunning = false
        statusMessage = "Stopped"
        // Put the system proxy back *before* the listener goes away, so the
        // Mac's apps never see a proxy that refuses connections.
        disableSystemProxy {
            server?.shutdown()
        }
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

    // MARK: - System proxy (this Mac)

    /// Trusts the CA if needed (so HTTPS from Mac apps decrypts), then points
    /// the Mac's network services at the proxy. Each step may show one admin
    /// prompt; a cancelled prompt turns the option off rather than nagging.
    private func enableSystemProxy() {
        guard let systemProxy else { return }
        systemProxyState = .configuring
        let needsTrust = trustState != .trusted
        let caManager = self.caManager
        let port = listenPort
        systemProxyQueue.async { [weak self] in
            var trust: CAManager.TrustState?
            if needsTrust, let caManager {
                _ = try? caManager.installAndTrust()
                trust = caManager.trustState()
            }
            let outcome = Result { try systemProxy.enable(host: "127.0.0.1", port: port) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let trust { self.trustState = trust }
                switch outcome {
                case .success(let services):
                    self.systemProxyState = .on(services)
                    self.statusMessage = "Capturing this Mac (\(services.joined(separator: ", ")))"
                case .failure(let error):
                    self.systemProxyState = .failed(String(describing: error))
                    self.statusMessage = "This Mac not captured: \(error)"
                    if case SystemProxyConfigurator.Failure.authorizationCancelled = error {
                        self.captureThisMac = false
                    }
                }
            }
        }
    }

    private func disableSystemProxy(then completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard let systemProxy, systemProxyState != .off else {
            completion?()
            return
        }
        systemProxyQueue.async { [weak self] in
            let outcome = Result { try systemProxy.restore() }
            Task { @MainActor [weak self] in
                switch outcome {
                case .success:
                    self?.systemProxyState = .off
                case .failure(let error):
                    self?.systemProxyState = .failed(String(describing: error))
                    self?.statusMessage = "Couldn't restore system proxy: \(error)"
                }
                completion?()
            }
        }
    }

    /// A snapshot left on disk means the last run died with the system proxy
    /// pointing at us. Restore it before anything else — a proxy nobody is
    /// listening on takes the whole Mac offline.
    private func recoverSystemProxyIfNeeded(_ configurator: SystemProxyConfigurator) async {
        guard configurator.hasSnapshot else { return }
        let port = listenPort
        let restored: Result<Bool, Error> = await withCheckedContinuation { continuation in
            systemProxyQueue.async {
                continuation.resume(returning: Result { try configurator.recoverIfNeeded(host: "127.0.0.1", port: port) })
            }
        }
        switch restored {
        case .success(true): statusMessage = "Restored this Mac's network settings from the last session"
        case .success(false): break
        case .failure(let error): statusMessage = "Couldn't restore system proxy: \(error)"
        }
    }

    /// Restore synchronously on normal quit and on SIGINT/SIGTERM (Ctrl-C under
    /// `swift run`, `kill`). A hard crash is covered by `recoverSystemProxyIfNeeded`.
    private func installRestoreOnExit() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreSystemProxyBlocking() }
        }
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.restoreSystemProxyBlocking() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func restoreSystemProxyBlocking() {
        guard let systemProxy, systemProxyState != .off else { return }
        systemProxyQueue.sync { try? systemProxy.restore() }
        systemProxyState = .off
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
