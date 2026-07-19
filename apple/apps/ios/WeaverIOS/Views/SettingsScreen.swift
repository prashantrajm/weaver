#if os(iOS)
import SwiftUI
import WeaverCore
import InspectorKit

/// Settings: capture options, the bypass list (reused rule shape from macOS
/// `BypassEditor`), and honest project/status info. No upsell, one license —
/// so there's deliberately no paywall or "upgrade" surface here.
struct SettingsScreen: View {
    @EnvironmentObject var store: IOSCaptureStore
    @State private var newBypass = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Capture") {
                    Toggle("Recording", isOn: $store.isRecording)
                    Toggle("Block HTTP/3", isOn: $store.blockHTTP3)
                    LabeledContent("Status", value: store.statusMessage)
                }

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
                    Text("Bypass (tunnel without decryption)")
                } footer: {
                    Text("Pinned or noisy hosts you want passed through untouched — their own TLS stays intact and no plaintext is captured.")
                }

                Section("Export") {
                    if let url = store.harExportURL(), !store.flows.isEmpty {
                        ShareLink(item: url) {
                            Label("Export session as HAR", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Text("Capture some traffic to export.").foregroundStyle(.secondary)
                    }
                }

                Section {
                    LabeledContent("Pricing", value: "One license · no nags")
                    LabeledContent("Capture backend", value: "In-app proxy")
                    LabeledContent("Proxy address", value: store.proxyAddress)
                } header: {
                    Text("About")
                } footer: {
                    Text("On-device HTTPS inspection — no desktop, no jailbreak. Capture runs through an in-app proxy: point this device's Wi-Fi proxy at the address above (foreground only). Automatic, backgrounded capture via a VPN network extension is the next step.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
#endif
