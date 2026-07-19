#if os(iOS)
import SwiftUI
import WeaverCore
import InspectorKit

/// The certificate half of setup. Cert onboarding is a first-class flow, not a
/// doc link, because it's the category's #1 complaint and its #1 silent failure.
/// We show *live, verified* trust state (from `TrustEvaluator`, which actually
/// asks SecTrust — not "did the user tap Install"), guide the two required
/// steps, and never claim success we haven't confirmed. Rendered inside the
/// Setup Guide's scroll/navigation, so it owns no `NavigationStack` of its own.
struct CertificateSetupSection: View {
    @EnvironmentObject var store: IOSCaptureStore
    @State private var showShare = false

    var body: some View {
        VStack(spacing: 16) {
            TrustStatusCard(status: store.trustStatus)

            StepCard(
                number: 1,
                title: "Install the profile",
                detail: "Opens a configuration profile carrying this install's CA. After tapping, go to Settings ▸ General ▸ VPN & Device Management ▸ Weaver CA ▸ Install.",
                isDone: store.trustStatus != .unknown
            ) {
                Button {
                    showShare = true
                } label: {
                    Label("Get Profile", systemImage: "arrow.down.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }

            StepCard(
                number: 2,
                title: "Enable Full Trust",
                detail: "Settings ▸ General ▸ About ▸ Certificate Trust Settings, then turn on the Weaver switch. This step silently doesn't appear for some users — if the switch is missing, reinstall the profile and reopen Settings.",
                isDone: store.trustStatus == .trusted
            ) {
                Button {
                    if let url = URL(string: "App-Prefs:") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }

            Button {
                store.refreshTrustStatus()
            } label: {
                Label("Re-check trust", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)

            CeilingNote()
        }
        .onAppear { store.refreshTrustStatus() }
        .sheet(isPresented: $showShare) {
            if let url = store.mobileConfigURL() {
                ShareSheet(url: url)
            } else {
                Text("Couldn't build the profile — the CA isn't ready yet.")
                    .padding()
                    .presentationDetents([.medium])
            }
        }
    }
}

/// Big, unambiguous live-state banner. Verified, not assumed.
private struct TrustStatusCard: View {
    let status: TrustEvaluator.Status

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(tint)
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .glassEffect(.regular.tint(tint.opacity(0.14)), in: .rect(cornerRadius: 22))
    }

    private var icon: String {
        switch status {
        case .trusted: return "checkmark.seal.fill"
        case .installedNotTrusted: return "exclamationmark.triangle.fill"
        case .unknown: return "seal"
        }
    }
    private var tint: Color {
        switch status {
        case .trusted: return .green
        case .installedNotTrusted: return .orange
        case .unknown: return .secondary
        }
    }
    private var title: String {
        switch status {
        case .trusted: return "Trusted & ready"
        case .installedNotTrusted: return "Almost there"
        case .unknown: return "Not set up"
        }
    }
    private var subtitle: String {
        switch status {
        case .trusted:
            return "iOS trusts the Weaver CA for TLS. Non-pinned apps on this device can be decrypted."
        case .installedNotTrusted:
            return "The profile is installed but Full Trust is still off. Finish step 2 — interception won't work until you do."
        case .unknown:
            return "The CA isn't installed yet. Do steps 1 and 2 to enable on-device HTTPS inspection."
        }
    }
}

private struct StepCard<Action: View>: View {
    let number: Int
    let title: String
    let detail: String
    let isDone: Bool
    @ViewBuilder let action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(isDone ? Color.green : Color.secondary.opacity(0.25))
                        .frame(width: 26, height: 26)
                    if isDone {
                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                    } else {
                        Text("\(number)").font(.caption.weight(.bold))
                    }
                }
                Text(title).font(.headline)
                Spacer()
            }
            Text(detail)
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            action()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

/// Honest about the MITM ceiling — never over-promise.
private struct CeilingNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("What this can't decrypt", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
            Text("Apps that pin their certificate (banking, hardened apps) and QUIC/HTTP-3 traffic can't be intercepted even when the CA is trusted. Weaver labels those flows honestly rather than showing them as failures.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// UIKit share sheet bridge for the `.mobileconfig` / HAR files.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
