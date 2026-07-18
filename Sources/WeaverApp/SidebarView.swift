import SwiftUI
import WeaverCore

/// Left sidebar: traffic grouped by client app and by domain — the core
/// app-and-domain mental model (M1.3). Counts update live.
struct SidebarView: View {
    @EnvironmentObject var controller: CaptureController
    @Binding var selection: SidebarSelection

    private var apps: [(name: String, count: Int)] {
        group(by: { $0.appDisplayName })
    }
    private var domains: [(name: String, count: Int)] {
        group(by: { $0.host })
    }

    var body: some View {
        List(selection: Binding(
            get: { selection },
            set: { if let value = $0 { selection = value } }
        )) {
            Label("All Traffic", systemImage: "globe")
                .tag(SidebarSelection.allTraffic)

            Section("Apps") {
                ForEach(apps, id: \.name) { item in
                    rowLabel(item.name, count: item.count, icon: "app.dashed")
                        .tag(SidebarSelection.app(item.name))
                        .contextMenu {
                            Button("Clear \(item.name) requests (\(item.count))", role: .destructive) {
                                controller.clearApp(item.name)
                                if selection == .app(item.name) { selection = .allTraffic }
                            }
                        }
                }
            }

            Section("Domains") {
                ForEach(domains, id: \.name) { item in
                    rowLabel(item.name, count: item.count, icon: "network")
                        .tag(SidebarSelection.domain(item.name))
                        .contextMenu {
                            Button("Clear \(item.name) requests (\(item.count))", role: .destructive) {
                                controller.clearDomain(item.name)
                                if selection == .domain(item.name) { selection = .allTraffic }
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

    private func group(by key: (Flow) -> String) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for flow in controller.flows { counts[key(flow), default: 0] += 1 }
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map { ($0.key, $0.value) }
    }
}
