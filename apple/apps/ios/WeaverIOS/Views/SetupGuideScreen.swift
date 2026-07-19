#if os(iOS) && WEAVER_VPN
import SwiftUI
import NetworkExtension
import WeaverCore
import InspectorKit

/// The one-stop "are we ready to capture?" screen. Two gates, both shown with
/// live state: the VPN packet-tunnel extension (running or not) and the CA
/// (installed + Full-Trust enabled or not). When both are green, capture works
/// with no manual Wi-Fi proxy.
struct SetupGuideScreen: View {
    @EnvironmentObject var store: IOSCaptureStore
    @EnvironmentObject var tunnel: TunnelController

    private var ready: Bool { tunnel.status == .connected && store.trustStatus == .trusted }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ReadyBanner(ready: ready)

                    Text("Two steps to start capturing this device's network traffic — no Wi-Fi proxy setup.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VPNCard()

                    CertificateSetupSection()
                }
                .padding(16)
            }
            .navigationTitle("Setup Guide")
            .background(.background)
        }
    }
}

/// Green when both gates pass; neutral otherwise.
private struct ReadyBanner: View {
    let ready: Bool
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: ready ? "checkmark.seal.fill" : "seal")
                .font(.system(size: 34))
                .foregroundStyle(ready ? .white : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(ready ? "Ready to Intercept" : "Not ready yet")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(ready ? .white : .primary)
                Text(ready ? "All systems configured correctly"
                           : "Finish the steps below to start capturing")
                    .font(.subheadline)
                    .foregroundStyle(ready ? .white.opacity(0.9) : .secondary)
            }
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if ready {
                RoundedRectangle(cornerRadius: 22)
                    .fill(LinearGradient(colors: [.green, .green.opacity(0.75)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .glassEffect(ready ? .clear : .regular, in: .rect(cornerRadius: 22))
    }
}

/// VPN extension gate: enable/disable the packet tunnel and show its live state.
private struct VPNCard: View {
    @EnvironmentObject var tunnel: TunnelController
    @State private var busy = false

    private var on: Bool { tunnel.isActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                statusDot
                VStack(alignment: .leading, spacing: 2) {
                    Text(on ? "VPN Extension Enabled" : "VPN Extension")
                        .font(.headline)
                        .foregroundStyle(on ? .green : .primary)
                    Text(statusText)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Button {
                busy = true
                Task {
                    if on { tunnel.stop() } else { await tunnel.start() }
                    busy = false
                }
            } label: {
                Label(on ? "Turn Off" : "Turn On Capture",
                      systemImage: on ? "stop.fill" : "bolt.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(on ? .red : .green)
            .disabled(busy || tunnel.status == .connecting || tunnel.status == .disconnecting)

            if let err = tunnel.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("The first time, iOS asks you to allow the VPN configuration. Capture runs in a background extension, so it keeps working when Weaver isn't open.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 26, height: 26)
            .overlay {
                Image(systemName: on ? "checkmark" : "bolt.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
    }

    private var dotColor: Color {
        switch tunnel.status {
        case .connected: return .green
        case .connecting, .reasserting, .disconnecting: return .orange
        default: return .secondary
        }
    }

    private var statusText: String {
        switch tunnel.status {
        case .connected: return "Running and capturing traffic"
        case .connecting: return "Connecting…"
        case .disconnecting: return "Stopping…"
        case .reasserting: return "Reconnecting…"
        case .disconnected: return "Off"
        case .invalid: return "Not installed yet"
        @unknown default: return "Unknown"
        }
    }
}
#endif
