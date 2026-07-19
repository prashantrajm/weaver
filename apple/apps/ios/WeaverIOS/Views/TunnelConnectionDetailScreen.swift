#if os(iOS)
import SwiftUI
import InspectorKit

/// Detail for one captured tunnel connection. Iteration 1 is connection-level
/// (no decrypted request/response yet), so this shows what the packet stack
/// actually knows — endpoint, protocol, live/closed state, byte counts — and is
/// honest that full HTTP bodies arrive once CA decryption lands. It reads the
/// live record from the poller by id, so byte counts keep ticking while open.
struct TunnelConnectionDetailScreen: View {
    @EnvironmentObject var captures: TunnelCaptureReader
    let recordID: UUID

    private var record: TunnelCaptureRecord? {
        captures.records.first { $0.id == recordID }
    }

    var body: some View {
        Group {
            if let record {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(record)
                        factsCard(record)
                        DecryptionNote(port: record.port, proto: record.proto)
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView("Connection cleared", systemImage: "bolt.slash",
                                       description: Text("This connection is no longer in the capture list."))
            }
        }
        .navigationTitle(record?.host ?? "Connection")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { captures.startPolling() }
    }

    private func header(_ record: TunnelCaptureRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: TunnelConnectionStyle.icon(record))
                    .font(.system(size: 22)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.host)
                        .font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(TunnelConnectionStyle.kind(record))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                statusPill(record)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func statusPill(_ record: TunnelCaptureRecord) -> some View {
        HStack(spacing: 5) {
            Circle().fill(record.closed ? Color.secondary : Color.green).frame(width: 8, height: 8)
            Text(record.closed ? "Closed" : "Live")
                .font(.caption.weight(.semibold))
                .foregroundStyle(record.closed ? Color.secondary : Color.green)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }

    private func factsCard(_ record: TunnelCaptureRecord) -> some View {
        VStack(spacing: 0) {
            factRow("Host", record.host)
            Divider()
            factRow("Destination IP", record.destIP)
            Divider()
            factRow("Port", String(record.port))
            Divider()
            factRow("Protocol", record.proto)
            Divider()
            factRow("Sent", FlowPresentation.byteString(record.bytesUp))
            Divider()
            factRow("Received", FlowPresentation.byteString(record.bytesDown))
            Divider()
            factRow("Started", record.startedAt.formatted(date: .omitted, time: .standard))
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline.monospaced())
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.vertical, 8)
    }
}

/// Honest explainer about why there's no request/response body yet, tuned to
/// what this specific connection is.
private struct DecryptionNote: View {
    let port: Int
    let proto: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(message).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private var message: String {
        if proto == "UDP" && port == 443 {
            return "This is QUIC (HTTP/3 over UDP). QUIC can't be decrypted by a proxy — it's part of the honest ceiling. The connection is captured; its contents aren't."
        }
        if port == 443 {
            return "This HTTPS connection is captured at the packet level. Decrypting it into full request/response — headers and body — needs the CA-based TLS interception that's the next build step."
        }
        if proto == "UDP" && port == 53 {
            return "A DNS lookup relayed through the tunnel. Full query/answer parsing is a later nicety."
        }
        return "Captured at the connection level. Full HTTP request/response inspection arrives with the decryption step."
    }
}
#endif
