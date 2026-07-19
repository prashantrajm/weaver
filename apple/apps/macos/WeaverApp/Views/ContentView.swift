import SwiftUI
import WeaverCore
import InspectorKit

/// Top-level three-region layout — the conventional inspector shell:
/// sidebar (grouping) · traffic list + type tabs · detail pane, with a toolbar
/// and a bottom status bar.
///
/// Screen state and all list/group derivation live in `InspectorViewModel`;
/// the captured data lives in `CaptureController`. This view just wires them
/// together and lays out the regions.
struct ContentView: View {
    @EnvironmentObject var controller: CaptureController
    @StateObject private var model = InspectorViewModel()

    var body: some View {
        let visibleFlows = model.filtered(controller.flows)
        VStack(spacing: 0) {
            ProxyToolbar()
            Divider()
            HSplitView {
                SidebarView(model: model)
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 340)

                VStack(spacing: 0) {
                    TypeFilterTabs(selection: $model.typeFilter)
                    Divider()
                    VSplitView {
                        TrafficListView(flows: visibleFlows, selection: $model.selectedFlowID)
                            .frame(minHeight: 180)
                        DetailPaneView(flow: model.selectedFlow(in: controller.flows))
                            .frame(minHeight: 180)
                    }
                }
                .frame(minWidth: 520)
            }
            Divider()
            StatusBar(searchText: $model.searchText, visibleCount: visibleFlows.count,
                      totalCount: controller.flows.count)
        }
        .task {
            await controller.bootstrap()
            controller.refreshTrustState()
        }
    }
}
