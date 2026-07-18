import SwiftUI
import WeaverCore

/// Type-filter quick tabs above the traffic list (All · HTTP · HTTPS · JSON …).
struct TypeFilterTabs: View {
    @Binding var selection: FlowKind?

    private let kinds: [FlowKind] = [.http, .https, .websocket, .json, .form, .xml, .js, .css, .document, .media]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                tab(title: "All", isSelected: selection == nil) { selection = nil }
                ForEach(kinds, id: \.self) { kind in
                    tab(title: kind.rawValue, isSelected: selection == kind) {
                        selection = (selection == kind) ? nil : kind
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func tab(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
                )
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

/// The main traffic table (M1.3). Columns: status · method · URL · client ·
/// status code · duration · size · SSL. Row formatting lives in
/// `FlowPresentation` so this view stays declarative.
struct TrafficListView: View {
    @EnvironmentObject var controller: CaptureController
    let flows: [Flow]
    @Binding var selection: Flow.ID?

    var body: some View {
        Table(flows, selection: $selection) {
            TableColumn("") { flow in
                Circle()
                    .fill(FlowPresentation.statusDotColor(flow))
                    .frame(width: 8, height: 8)
            }
            .width(18)

            TableColumn("Method") { flow in
                Text(flow.method)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(FlowPresentation.methodColor(flow.method))
            }
            .width(min: 50, ideal: 60)

            TableColumn("URL") { flow in
                VStack(alignment: .leading, spacing: 1) {
                    Text(flow.host).font(.system(size: 12, weight: .medium))
                    Text(flow.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .width(min: 200, ideal: 340)

            TableColumn("Client") { flow in
                Text(FlowPresentation.clientName(flow)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 110)

            TableColumn("Status") { flow in
                if flow.bypassed {
                    Text("BYPASS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .help("Tunnelled without decryption (host on bypass list)")
                } else if flow.tlsInterceptionFailed {
                    Text("PINNED")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)
                        .help("Client rejected our certificate — likely pinning or CA not trusted on the device")
                } else if let code = flow.statusCode {
                    Text("\(code)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(FlowPresentation.statusCodeColor(code))
                } else if flow.error != nil {
                    Text("ERR").font(.system(size: 11, design: .monospaced)).foregroundStyle(.red)
                } else {
                    Text("…").foregroundStyle(.secondary)
                }
            }
            .width(min: 50, ideal: 60)

            TableColumn("Duration") { flow in
                Text(flow.durationMS.map { String(format: "%.0f ms", $0) } ?? "–")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 74)

            TableColumn("Size") { flow in
                Text(FlowPresentation.byteString(flow.responseSize))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 74)

            TableColumn("SSL") { flow in
                Image(systemName: flow.isTLS ? "lock.fill" : "lock.open")
                    .font(.system(size: 10))
                    .foregroundStyle(flow.isTLS ? .green : .secondary)
            }
            .width(34)

            TableColumn("Proto") { flow in
                HStack(spacing: 3) {
                    Text(FlowPresentation.protoLabel(flow))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(flow.isWebSocket ? .purple : .secondary)
                    if flow.serverAdvertisedHTTP3 {
                        Text("h3")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.orange)
                            .help("Server offered HTTP/3; kept on TCP so it stayed capturable")
                    }
                }
            }
            .width(60)
        }
        .tableStyle(.inset)
        .font(.system(size: 12))
        .contextMenu(forSelectionType: Flow.ID.self) { ids in
            if let id = ids.first, let flow = flows.first(where: { $0.id == id }) {
                Button("Bypass \(flow.host)") { controller.addBypass(flow.host) }
                if let wildcard = FlowPresentation.parentWildcard(of: flow.host) {
                    Button("Bypass \(wildcard)") { controller.addBypass(wildcard) }
                }
            }
        }
    }
}
