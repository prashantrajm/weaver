import SwiftUI
import WeaverCore

/// Top toolbar: record/clear on the left, a status pill in the center, and CA
/// trust + export controls on the right.
struct ProxyToolbar: View {
    @EnvironmentObject var controller: CaptureController

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

            Menu {
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
                 ? "Listening on \(controller.listenHost):\(controller.listenPort)"
                 : controller.statusMessage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
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
                Label("Trust CA", systemImage: "exclamationmark.triangle.fill")
            }
            .tint(.orange)
        case .notInstalled:
            Button(action: controller.installAndTrustCA) {
                Label("Install & Trust CA", systemImage: "lock.shield")
            }
        }
    }
}
