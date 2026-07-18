import SwiftUI
import WeaverCore

/// Top toolbar: record/clear on the left, a status pill in the center, and CA
/// trust + export controls on the right.
struct ProxyToolbar: View {
    @EnvironmentObject var controller: CaptureController
    @State private var showBypass = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: controller.toggleRun) {
                Label(controller.isRunning ? "Stop" : "Start",
                      systemImage: controller.isRunning ? "stop.fill" : "play.fill")
            }
            .help(controller.isRunning ? "Stop the proxy" : "Start the proxy")

            Button(action: { controller.isRecording.toggle() }) {
                Label(controller.isRecording ? "Recording" : "Paused",
                      systemImage: controller.isRecording ? "record.circle" : "pause.circle")
            }
            .disabled(!controller.isRunning)

            Button(action: controller.clear) {
                Label("Clear", systemImage: "trash")
            }

            Spacer()

            statusPill

            Spacer()

            trustControl

            Button {
                showBypass = true
            } label: {
                Label("Bypass\(controller.bypassList.isEmpty ? "" : " (\(controller.bypassList.count))")",
                      systemImage: "lock.open")
            }
            .help("Manage hosts tunnelled without decryption")
            .popover(isPresented: $showBypass, arrowEdge: .bottom) {
                BypassEditorView().environmentObject(controller)
            }

            Menu {
                Toggle("Block HTTP/3 (force TCP for capture)", isOn: $controller.blockHTTP3)
                Divider()
                Button("Reveal CA Certificate in Finder", action: controller.revealCACertificate)
                Button("Re-check Trust State", action: controller.refreshTrustState)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 40)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(controller.isRunning ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(controller.isRunning
                 ? "Proxy \(controller.deviceProxyHost):\(controller.listenPort)"
                 : controller.statusMessage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if controller.isRunning {
                Button {
                    copyProxyAddress()
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Copy the proxy address to set on your device's Wi-Fi")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    private func copyProxyAddress() {
        let text = "\(controller.deviceProxyHost):\(controller.listenPort)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @ViewBuilder
    private var trustControl: some View {
        switch controller.trustState {
        case .trusted:
            Label("CA Trusted", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.system(size: 12, weight: .medium))
        case .installedNotTrusted:
            Button(action: controller.installAndTrustCA) {
                Label("Trust CA (Mac)", systemImage: "exclamationmark.triangle.fill")
            }
            .tint(.orange)
            .help("Trusts the CA in the Mac System keychain — only needed to capture Mac apps. For iPhone/Android capture, install the CA on the device instead.")
        case .notInstalled:
            Button(action: controller.installAndTrustCA) {
                Label("Install CA (Mac)", systemImage: "lock.shield")
            }
            .help("Installs the CA in the Mac System keychain — only needed to capture Mac apps. For device capture, install the CA on the device instead.")
        }
    }
}
