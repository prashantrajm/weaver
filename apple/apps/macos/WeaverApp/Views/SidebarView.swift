import SwiftUI
import WeaverCore
import InspectorKit

/// Left sidebar: traffic grouped by client app and by domain — the core
/// app-and-domain mental model (M1.3). Counts update live. Grouping and selection
/// state live in `InspectorViewModel`; this view renders them.
struct SidebarView: View {
    @EnvironmentObject var controller: CaptureController
    @ObservedObject var model: InspectorViewModel

    var body: some View {
        let apps = model.appGroups(controller.flows)
        let domains = model.domainGroups(controller.flows)

        List(selection: Binding(
            get: { model.sidebarSelection },
            set: { if let value = $0 { model.sidebarSelection = value } }
        )) {
            Label("All Traffic", systemImage: "globe")
                .tag(SidebarSelection.allTraffic)

            Section("Apps") {
                ForEach(apps) { item in
                    rowLabel(item.name, count: item.count, icon: "app.dashed")
                        .tag(SidebarSelection.app(item.name))
                        .contextMenu {
                            Button("Clear \(item.name) requests (\(item.count))", role: .destructive) {
                                controller.clearApp(item.name)
                                if model.sidebarSelection == .app(item.name) { model.sidebarSelection = .allTraffic }
                            }
                        }
                }
            }

            Section("Domains") {
                ForEach(domains) { item in
                    rowLabel(item.name, count: item.count, icon: "network")
                        .tag(SidebarSelection.domain(item.name))
                        .contextMenu {
                            Button("Clear \(item.name) requests (\(item.count))", role: .destructive) {
                                controller.clearDomain(item.name)
                                if model.sidebarSelection == .domain(item.name) { model.sidebarSelection = .allTraffic }
                            }
                            Button("Bypass \(item.name)") { controller.addBypass(item.name) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func rowLabel(_ name: String, count: Int, icon: String) -> some View {
        HStack {
            Label(name, systemImage: icon)
                .lineLimit(1)
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }
    }
}
