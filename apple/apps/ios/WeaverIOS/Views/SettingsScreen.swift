#if os(iOS)
import SwiftUI
import WeaverCore
import InspectorKit

/// Settings is the app's "everything else" hub: a live
/// readiness banner up top, then Intercept Traffic (setup + proxy switch),
/// Tools (certificates, bypass list, export), capture options, and honest
/// About info. No upsell, one license — so there's deliberately no paywall or
/// "upgrade" surface here.
struct SettingsScreen: View {
    @EnvironmentObject var store: IOSCaptureStore
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ReadinessBanner(trust: store.trustStatus, isRunning: store.isRunning)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                Section("Intercept Traffic") {
                    NavigationLink {
                        HowToSetupScreen()
                    } label: {
                        SettingsRow(icon: "book.pages.fill", tint: .blue, title: "How to Set Up")
                    }
                    Toggle(isOn: proxyRunning) {
                        SettingsRow(icon: "wifi", tint: .green, title: "Proxy",
                                    subtitle: store.statusMessage)
                    }
                    LabeledContent {
                        Button {
                            UIPasteboard.general.string = store.proxyAddress
                        } label: {
                            HStack(spacing: 6) {
                                Text(store.proxyAddress).font(.callout.monospaced())
                                Image(systemName: "doc.on.doc").font(.caption2)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    } label: {
                        SettingsRow(icon: "number", tint: .gray, title: "Address")
                    }
                }

                Section("Tools") {
                    NavigationLink {
                        CertificateScreen()
                    } label: {
                        SettingsRow(icon: "checkmark.seal.fill", tint: .orange, title: "Certificates")
                            .badge(trustBadge)
                    }
                    NavigationLink {
                        BypassListScreen()
                    } label: {
                        SettingsRow(icon: "arrow.triangle.branch", tint: .purple, title: "Bypass List")
                            .badge(store.bypassList.count)
                    }
                    if let url = store.harExportURL(), !store.flows.isEmpty {
                        ShareLink(item: url) {
                            SettingsRow(icon: "square.and.arrow.up.fill", tint: .indigo,
                                        title: "Export Session as HAR")
                        }
                    } else {
                        SettingsRow(icon: "square.and.arrow.up.fill", tint: .indigo,
                                    title: "Export Session as HAR",
                                    subtitle: "Capture some traffic first")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Appearance") {
                    Picker(selection: $appearance) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.icon).tag(mode)
                        }
                    } label: {
                        SettingsRow(icon: "circle.lefthalf.filled", tint: .indigo, title: "Theme")
                    }
                    .pickerStyle(.navigationLink)
                }

                Section {
                    Toggle(isOn: $store.isRecording) {
                        SettingsRow(icon: "record.circle.fill", tint: .red, title: "Recording")
                    }
                    Toggle(isOn: $store.blockHTTP3) {
                        SettingsRow(icon: "bolt.slash.fill", tint: .teal, title: "Block HTTP/3")
                    }
                } header: {
                    Text("Capture Options")
                } footer: {
                    Text("Blocking HTTP/3 strips h3 Alt-Svc so apps stay on capturable TCP. QUIC itself can't be decrypted.")
                }

                Section {
                    if let version = appVersion {
                        LabeledContent("Version", value: version)
                    }
                    LabeledContent("Capture backend", value: "In-app proxy")
                } header: {
                    Text("About")
                } footer: {
                    Text("On-device HTTPS inspection — no desktop, no jailbreak. Capture runs through an in-app proxy and only works while Weaver is in the foreground; backgrounding the app stops it. Automatic, backgrounded capture via a VPN network extension is the next step.")
                }
            }
            .navigationTitle("Settings")
            .onAppear { store.refreshTrustStatus() }
        }
    }

    /// `isRunning` is private(set); the switch drives it through `toggleRun()`.
    private var proxyRunning: Binding<Bool> {
        Binding(
            get: { store.isRunning },
            set: { newValue in
                if newValue != store.isRunning { store.toggleRun() }
            }
        )
    }

    private var trustBadge: Text? {
        switch store.trustStatus {
        case .trusted: return nil
        case .installedNotTrusted: return Text("Action needed").foregroundStyle(.orange)
        case .unknown: return Text("Not installed").foregroundStyle(.secondary)
        }
    }

    private var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}

/// Live readiness state, verified not assumed: CA trust comes from
/// `TrustEvaluator` (SecTrust) and the proxy state from the store. Green only
/// when both halves are actually in place.
private struct ReadinessBanner: View {
    let trust: TrustEvaluator.Status
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(tint.opacity(0.14)), in: .rect(cornerRadius: 22))
    }

    private var ready: Bool { trust == .trusted && isRunning }

    private var icon: String {
        if ready { return "checkmark.seal.fill" }
        switch trust {
        case .trusted: return "pause.circle.fill"
        case .installedNotTrusted: return "exclamationmark.triangle.fill"
        case .unknown: return "seal"
        }
    }
    private var tint: Color {
        if ready { return .green }
        return trust == .installedNotTrusted ? .orange : .secondary
    }
    private var title: String {
        if ready { return "Ready to intercept" }
        switch trust {
        case .trusted: return "Proxy stopped"
        case .installedNotTrusted: return "Almost there"
        case .unknown: return "Not set up"
        }
    }
    private var subtitle: String {
        if ready {
            return "CA trusted and proxy running — point this device's Wi-Fi proxy at the address below."
        }
        switch trust {
        case .trusted:
            return "The CA is trusted. Turn the proxy on to start capturing."
        case .installedNotTrusted:
            return "The profile is installed but Full Trust is off. Finish setup in Certificates."
        case .unknown:
            return "Install and trust the CA in Certificates, then turn the proxy on."
        }
    }
}

/// Settings-style row: tinted rounded-square icon tile + title (+ optional
/// secondary line), matching the system Settings visual language.
private struct SettingsRow: View {
    let icon: String
    let tint: Color
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// Full Wi-Fi-proxy walkthrough + self-test, pushed from Settings. Reuses the
/// same `CaptureSetupCard` shown on the Traffic tab's empty state.
private struct HowToSetupScreen: View {
    var body: some View {
        ScrollView {
            CaptureSetupCard()
                .padding(.vertical, 16)
        }
        .navigationTitle("How to Set Up")
        .navigationBarTitleDisplayMode(.inline)
        .background(.background)
    }
}

/// Bypass-list editor, pushed from Settings ▸ Tools. Same rule shape as the
/// macOS `BypassEditor`.
private struct BypassListScreen: View {
    @EnvironmentObject var store: IOSCaptureStore
    @State private var newBypass = ""

    var body: some View {
        Form {
            Section {
                ForEach(store.bypassList, id: \.self) { pattern in
                    Text(pattern).font(.callout.monospaced())
                        .swipeActions {
                            Button("Remove", role: .destructive) { store.removeBypass(pattern) }
                        }
                }
                HStack {
                    TextField("host or *.example.com", text: $newBypass)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                    Button("Add") {
                        store.addBypass(newBypass)
                        newBypass = ""
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .disabled(newBypass.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Tunnel without decryption")
            } footer: {
                Text("Pinned or noisy hosts you want passed through untouched — their own TLS stays intact and no plaintext is captured.")
            }
        }
        .navigationTitle("Bypass List")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
