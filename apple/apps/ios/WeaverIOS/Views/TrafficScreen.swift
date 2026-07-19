#if os(iOS)
import SwiftUI
import WeaverCore
import InspectorKit

/// The main capture screen. iPhone default per the plan: a domain-grouped list
/// (scannable folder rows with per-domain counts), a
/// content-type filter chip bar, an inline search field, and a
/// floating Liquid Glass capture control. Tapping a domain pushes its request
/// list; tapping a request pushes the detail screen.
struct TrafficScreen: View {
    @EnvironmentObject var store: IOSCaptureStore
    @EnvironmentObject var inspector: InspectorViewModel
    @EnvironmentObject var captures: TunnelCaptureReader

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                content
                CaptureControlBar()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            .navigationTitle("Traffic")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $inspector.searchText, prompt: "Search URL, method, host")
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .top, spacing: 0) {
                FilterChipBar(selection: $inspector.typeFilter)
            }
            .navigationDestination(for: SidebarSelection.self) { selection in
                DomainRequestsScreen(selection: selection)
            }
            .navigationDestination(for: Flow.ID.self) { id in
                FlowDetailScreen(flowID: id)
            }
            .navigationDestination(for: TunnelRecordID.self) { ref in
                TunnelConnectionDetailScreen(recordID: ref.value)
            }
            .onAppear { captures.startPolling() }
            .onDisappear { captures.stopPolling() }
            .onChange(of: captures.flowRecords, initial: true) { _, records in
                store.setTunnelFlows(records)
            }
        }
    }

    private var tunnelRecords: [TunnelCaptureRecord] {
        // 443/TCP is shown decrypted in the request list, so keep only the rest
        // here (DNS, QUIC, plain HTTP, other TCP) to avoid duplicating rows.
        let base = captures.records.filter { !($0.proto == "TCP" && $0.port == 443) }
        guard !inspector.searchText.isEmpty else { return base }
        let q = inspector.searchText.lowercased()
        return base.filter { $0.host.lowercased().contains(q) || $0.note.lowercased().contains(q) }
    }

    private var filtered: [Flow] {
        // Domain list *is* the selector, so ignore sidebarSelection here; honor
        // only the type filter and search text. `filtered(_:)` already applies
        // both, and the home tab always keeps sidebarSelection == .allTraffic.
        inspector.filtered(store.flows)
    }

    @ViewBuilder
    private var content: some View {
        if store.flows.isEmpty && tunnelRecords.isEmpty {
            ScrollView {
                VStack(spacing: 16) {
                    EmptyCaptureState(isRunning: store.isRunning)
                        .frame(maxWidth: .infinity)
                    CaptureSetupCard()
                }
                .padding(.top, 40)
                .padding(.bottom, 120)
            }
        } else {
            List {
                if !inspector.domainGroups(filtered).isEmpty {
                    Section {
                        ForEach(inspector.domainGroups(filtered)) { group in
                            NavigationLink(value: SidebarSelection.domain(group.name)) {
                                DomainRow(group: group)
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                    } header: {
                        Label("Requests (decrypted)", systemImage: "lock.open.fill")
                    }
                }
                if !tunnelRecords.isEmpty {
                    Section {
                        ForEach(tunnelRecords) { record in
                            NavigationLink(value: TunnelRecordID(value: record.id)) {
                                TunnelConnectionRow(record: record)
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                    } header: {
                        Label("Other connections", systemImage: "dot.radiowaves.left.and.right")
                    } footer: {
                        Text("Non-HTTPS traffic (DNS, QUIC, plain HTTP). A green dot means live, grey means closed. QUIC can't be decrypted — it's part of the honest ceiling.")
                    }
                }
            }
            .listStyle(.plain)
            .contentMargins(.bottom, 88, for: .scrollContent)  // clear the capture bar
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Clear", systemImage: "trash", role: .destructive) {
                store.clear()
                captures.clear()
            }
            .disabled(store.flows.isEmpty && captures.records.isEmpty)
        }
        ToolbarItem(placement: .topBarTrailing) {
            if let url = store.harExportURL(), !store.flows.isEmpty {
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Toggle("Recording", isOn: $store.isRecording)
                Toggle("Block HTTP/3 (keep capturable)", isOn: $store.blockHTTP3)
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }
}

/// One captured tunnel connection: live/closed dot, host, protocol/note, bytes.
private struct TunnelConnectionRow: View {
    let record: TunnelCaptureRecord

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: TunnelConnectionStyle.icon(record))
                    .font(.system(size: 18))
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                Circle()
                    .fill(record.closed ? Color.secondary : Color.green)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(record.host)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(record.note).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("↑\(FlowPresentation.byteString(record.bytesUp)) ↓\(FlowPresentation.byteString(record.bytesDown))")
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(":\(record.port)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

/// Shared icon/label logic for a tunnel connection (row + detail).
enum TunnelConnectionStyle {
    static func icon(_ record: TunnelCaptureRecord) -> String {
        switch record.proto {
        case "UDP": return record.port == 53 ? "list.bullet.rectangle" : "dot.radiowaves.left.and.right"
        default: return record.port == 443 ? "lock.fill" : "network"
        }
    }

    static func kind(_ record: TunnelCaptureRecord) -> String {
        if record.proto == "UDP" { return record.port == 53 ? "DNS lookup" : (record.port == 443 ? "QUIC (encrypted)" : "UDP") }
        if record.port == 443 { return "HTTPS (encrypted)" }
        if record.port == 80 { return "HTTP" }
        return "TCP"
    }
}

/// One folder-style row: a domain, its trust/lock state, and its request count.
private struct DomainRow: View {
    let group: FlowGroup

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 20))
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("^[\(group.count) request](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

/// Floating Liquid Glass start/stop control with a live status line.
private struct CaptureControlBar: View {
    @EnvironmentObject var store: IOSCaptureStore

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    store.toggleRun()
                } label: {
                    Label(store.isRunning ? "Stop" : "Start",
                          systemImage: store.isRunning ? "stop.fill" : "play.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(store.isRunning ? .red : .green)

                VStack(alignment: .leading, spacing: 1) {
                    Text(store.isRunning ? "Capturing" : "Idle")
                        .font(.caption.weight(.semibold))
                    Text(store.statusMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
    }
}

private struct EmptyCaptureState: View {
    let isRunning: Bool
    var body: some View {
        ContentUnavailableView {
            Label(isRunning ? "Waiting for traffic" : "Not capturing",
                  systemImage: "antenna.radiowaves.left.and.right")
        } description: {
            Text(isRunning
                 ? "Requests from this device will appear here as apps make them."
                 : "Tap Start to begin capturing this device's HTTPS traffic.")
        }
    }
}

/// How to capture real traffic: point the device's Wi-Fi proxy at the in-app
/// proxy, or tap Run self-test to prove the pipeline works right now.
private struct CaptureSetupCard: View {
    @EnvironmentObject var store: IOSCaptureStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Capture real traffic", systemImage: "point.3.filled.connected.trianglepath.dotted")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                stepLine("1", "Start the proxy below.")
                stepLine("2", "iOS Settings ▸ Wi-Fi ▸ (i) ▸ Configure Proxy ▸ Manual.")
                HStack(spacing: 6) {
                    Text("3").font(.caption.weight(.bold).monospaced())
                        .frame(width: 16)
                    Text("Server ")
                        .font(.subheadline).foregroundStyle(.secondary)
                    + Text(store.listenHost).font(.subheadline.monospaced())
                    + Text("  Port ").font(.subheadline).foregroundStyle(.secondary)
                    + Text(verbatim: String(store.listenPort)).font(.subheadline.monospaced())
                    Spacer()
                    Button {
                        UIPasteboard.general.string = store.listenHost
                    } label: {
                        Image(systemName: "doc.on.doc").font(.caption)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .help("Copy server address")
                }
                stepLine("4", "Install & trust the CA in the Certificate tab.")
            }

            Button {
                if let url = URL(string: "App-Prefs:") { UIApplication.shared.open(url) }
            } label: {
                Label("Open Settings", systemImage: "gearshape")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .font(.subheadline)

            Divider()

            HStack(spacing: 10) {
                Button {
                    store.runSelfTest()
                } label: {
                    Label(selfTestLabel, systemImage: selfTestIcon)
                }
                .buttonStyle(.glassProminent)
                .disabled(store.selfTestState == .running)

                if case .passed(let status) = store.selfTestState {
                    Text("HTTP \(status)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.green)
                } else if case .failed = store.selfTestState {
                    Text("failed").font(.caption).foregroundStyle(.red)
                }
                Spacer()
            }
            Text("The self-test sends one real HTTPS request through the proxy — no Wi-Fi setup needed — so a genuine decrypted flow appears above.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 16)
    }

    private var selfTestLabel: String {
        switch store.selfTestState {
        case .running: return "Testing…"
        default: return "Run self-test"
        }
    }
    private var selfTestIcon: String {
        switch store.selfTestState {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        default: return "bolt.fill"
        }
    }

    private func stepLine(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(n).font(.caption.weight(.bold).monospaced()).frame(width: 16)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
