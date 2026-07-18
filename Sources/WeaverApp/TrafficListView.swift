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
/// status code · duration · size · SSL.
struct TrafficListView: View {
    let flows: [Flow]
    @Binding var selection: Flow.ID?

    var body: some View {
        Table(flows, selection: $selection) {
            TableColumn("") { flow in
                Circle()
                    .fill(statusColor(flow))
                    .frame(width: 8, height: 8)
            }
            .width(18)

            TableColumn("Method") { flow in
                Text(flow.method)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(methodColor(flow.method))
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
                Text(clientName(flow)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 110)

            TableColumn("Status") { flow in
                if let code = flow.statusCode {
                    Text("\(code)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(statusCodeColor(code))
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
                Text(byteString(flow.responseSize))
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
                Text(protoLabel(flow))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(flow.isWebSocket ? .purple : .secondary)
            }
            .width(46)
        }
        .tableStyle(.inset)
        .font(.system(size: 12))
    }

    private func protoLabel(_ flow: Flow) -> String {
        if flow.isWebSocket { return "WS" }
        return flow.httpVersion.contains("2") ? "H2" : "H1"
    }

    private func clientName(_ flow: Flow) -> String {
        flow.clientDescription.split(separator: "/").first.map(String.init)
            ?? (flow.clientDescription.isEmpty ? "—" : flow.clientDescription)
    }

    private func statusColor(_ flow: Flow) -> Color {
        if flow.error != nil { return .red }
        return flow.completedAt == nil ? .yellow : .green
    }

    private func methodColor(_ method: String) -> Color {
        switch method {
        case "GET": return .blue
        case "POST": return .green
        case "PUT", "PATCH": return .orange
        case "DELETE": return .red
        default: return .primary
        }
    }

    private func statusCodeColor(_ code: Int) -> Color {
        switch code {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        default: return .red
        }
    }

    private func byteString(_ bytes: Int) -> String {
        if bytes == 0 { return "–" }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}
