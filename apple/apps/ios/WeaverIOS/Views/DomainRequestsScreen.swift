#if os(iOS)
import SwiftUI
import WeaverCore
import InspectorKit

/// The request list for one domain (or app), pushed from the home list. Each
/// row is a compact request summary; tapping pushes the detail screen. Row
/// formatting comes entirely from `FlowPresentation` so the view stays thin.
struct DomainRequestsScreen: View {
    @EnvironmentObject var store: IOSCaptureStore
    @EnvironmentObject var inspector: InspectorViewModel
    let selection: SidebarSelection

    var body: some View {
        List {
            ForEach(flows) { flow in
                NavigationLink(value: flow.id) {
                    RequestRow(flow: flow)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if case .domain(let host) = selection {
                    Button("Clear", systemImage: "trash", role: .destructive) {
                        store.clearDomain(host)
                    }
                }
            }
        }
        .overlay {
            if flows.isEmpty {
                ContentUnavailableView("No requests", systemImage: "tray",
                                       description: Text("Nothing matches the current filter here yet."))
            }
        }
    }

    private var title: String {
        switch selection {
        case .allTraffic: return "All Traffic"
        case .app(let name): return name
        case .domain(let host): return host
        }
    }

    private var flows: [Flow] {
        store.flows.filter { flow in
            switch selection {
            case .allTraffic: return true
            case .app(let name): return flow.appDisplayName == name
            case .domain(let host): return flow.host == host
            }
        }.filter { flow in
            guard let typeFilter = inspector.typeFilter else { return true }
            return flow.kind == typeFilter
        }
    }
}

/// A single request row: status dot, method, path, status code, size/duration.
struct RequestRow: View {
    let flow: Flow

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(FlowPresentation.statusDotColor(flow))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(flow.method)
                        .font(.caption.weight(.bold).monospaced())
                        .foregroundStyle(FlowPresentation.methodColor(flow.method))
                    Text(flow.path.isEmpty ? "/" : flow.path)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 8) {
                    statusBadge
                    Text(FlowPresentation.protoLabel(flow))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    if let ms = flow.durationMS {
                        Text(String(format: "%.0f ms", ms))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text(FlowPresentation.byteString(flow.responseSize))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: flow.isTLS ? "lock.fill" : "lock.open")
                .font(.caption2)
                .foregroundStyle(flow.isTLS ? .green : .secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if flow.bypassed {
            Text("BYPASS").font(.caption2.weight(.bold).monospaced()).foregroundStyle(.secondary)
        } else if flow.tlsInterceptionFailed {
            Text("PINNED").font(.caption2.weight(.bold).monospaced()).foregroundStyle(.orange)
        } else if let code = flow.statusCode {
            Text("\(code)")
                .font(.caption2.weight(.semibold).monospaced())
                .foregroundStyle(FlowPresentation.statusCodeColor(code))
        } else if flow.error != nil {
            Text("ERR").font(.caption2.weight(.bold).monospaced()).foregroundStyle(.red)
        } else {
            Text("…").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
#endif
