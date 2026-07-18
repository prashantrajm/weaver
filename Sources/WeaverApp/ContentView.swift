import SwiftUI
import WeaverCore

/// Top-level three-region layout — the conventional inspector shell:
/// sidebar (grouping) · traffic list + type tabs · detail pane, with a toolbar
/// and a bottom status bar.
struct ContentView: View {
    @EnvironmentObject var controller: CaptureController

    @State private var selectedFlowID: Flow.ID?
    @State private var searchText = ""
    @State private var typeFilter: FlowKind? = nil
    @State private var sidebarSelection: SidebarSelection = .allTraffic

    private var filteredFlows: [Flow] {
        controller.flows.filter { flow in
            if let typeFilter, flow.kind != typeFilter { return false }
            switch sidebarSelection {
            case .allTraffic: break
            case .app(let name): if flow.clientDescription != name { return false }
            case .domain(let host): if flow.host != host { return false }
            }
            if !searchText.isEmpty {
                let haystack = "\(flow.url.absoluteString) \(flow.method) \(flow.host)".lowercased()
                if !haystack.contains(searchText.lowercased()) { return false }
            }
            return true
        }
    }

    private var selectedFlow: Flow? {
        controller.flows.first { $0.id == selectedFlowID }
    }

    var body: some View {
        VStack(spacing: 0) {
            ProxyToolbar()
            Divider()
            HSplitView {
                SidebarView(selection: $sidebarSelection)
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 340)

                VStack(spacing: 0) {
                    TypeFilterTabs(selection: $typeFilter)
                    Divider()
                    VSplitView {
                        TrafficListView(flows: filteredFlows, selection: $selectedFlowID)
                            .frame(minHeight: 180)
                        DetailPaneView(flow: selectedFlow)
                            .frame(minHeight: 180)
                    }
                }
                .frame(minWidth: 520)
            }
            Divider()
            StatusBar(searchText: $searchText, visibleCount: filteredFlows.count,
                      totalCount: controller.flows.count)
        }
        .onAppear { controller.refreshTrustState() }
    }
}

enum SidebarSelection: Hashable {
    case allTraffic
    case app(String)
    case domain(String)
}
