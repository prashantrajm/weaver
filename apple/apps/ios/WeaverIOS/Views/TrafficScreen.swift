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
        }
    }

    private var filtered: [Flow] {
        // Domain list *is* the selector, so ignore sidebarSelection here; honor
        // only the type filter and search text. `filtered(_:)` already applies
        // both, and the home tab always keeps sidebarSelection == .allTraffic.
        inspector.filtered(store.flows)
    }

    @ViewBuilder
    private var content: some View {
        if store.flows.isEmpty {
            EmptyCaptureState(isRunning: store.isRunning)
        } else {
            List {
                if store.isDemoCapture {
                    DemoDataBanner()
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowSeparator(.hidden)
                }
                ForEach(inspector.domainGroups(filtered)) { group in
                    NavigationLink(value: SidebarSelection.domain(group.name)) {
                        DomainRow(group: group)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            }
            .listStyle(.plain)
            .contentMargins(.bottom, 88, for: .scrollContent)  // clear the capture bar
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Clear", systemImage: "trash", role: .destructive) { store.clear() }
                .disabled(store.flows.isEmpty)
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

/// Honest label: the current data is demo, not live capture.
private struct DemoDataBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
            Text("Demo data — the on-device VPN tunnel ships in iOS-P1")
                .font(.caption)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(10)
        .glassEffect(.regular.tint(.yellow.opacity(0.18)), in: .rect(cornerRadius: 14))
    }
}
#endif
