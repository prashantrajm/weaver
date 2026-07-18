import SwiftUI
import WeaverCore

/// Split Request | Response detail pane with Header/Query/Body/Raw tabs and
/// content-aware pretty-printing (M1.3).
struct DetailPaneView: View {
    let flow: Flow?

    var body: some View {
        if let flow {
            VStack(spacing: 0) {
                summaryBar(flow)
                Divider()
                if flow.tlsInterceptionFailed {
                    PinningExplanationView(flow: flow)
                } else if flow.isWebSocket {
                    HSplitView {
                        MessagePane(title: "Handshake",
                                    headers: flow.requestHeaders,
                                    bodyData: nil,
                                    url: flow.url,
                                    contentType: nil)
                        WebSocketMessagesView(flow: flow)
                    }
                } else {
                    HSplitView {
                        MessagePane(title: "Request",
                                    headers: flow.requestHeaders,
                                    bodyData: flow.requestBody,
                                    url: flow.url,
                                    contentType: flow.requestHeaders.first { $0.name.lowercased() == "content-type" }?.value)
                        MessagePane(title: "Response",
                                    headers: flow.responseHeaders,
                                    bodyData: flow.responseBody,
                                    url: flow.url,
                                    contentType: flow.contentType)
                    }
                }
            }
        } else {
            VStack {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 28)).foregroundStyle(.tertiary)
                Text("Select a request to inspect")
                    .foregroundStyle(.secondary).padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func summaryBar(_ flow: Flow) -> some View {
        HStack(spacing: 8) {
            Text(flow.method)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.2)))
            if let code = flow.statusCode {
                Text("\(code)").font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            Text(flow.url.absoluteString)
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let error = flow.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

private struct MessagePane: View {
    let title: String
    let headers: [HTTPHeader]
    let bodyData: Data?
    let url: URL
    let contentType: String?

    enum Tab: String, CaseIterable { case header = "Header", query = "Query", body = "Body", raw = "Raw" }
    @State private var tab: Tab = .header

    private var queryItems: [(String, String)] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .map { ($0.name, $0.value ?? "") } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            Divider()
            content
        }
        .frame(minWidth: 260)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .header:
            KeyValueList(pairs: headers.map { ($0.name, $0.value) })
        case .query:
            KeyValueList(pairs: queryItems)
        case .body:
            BodyView(data: bodyData, contentType: contentType, raw: false)
        case .raw:
            BodyView(data: bodyData, contentType: contentType, raw: true)
        }
    }
}

private struct KeyValueList: View {
    let pairs: [(String, String)]
    var body: some View {
        if pairs.isEmpty {
            EmptyPane(text: "None")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                        HStack(alignment: .top, spacing: 8) {
                            Text(pair.0)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 160, alignment: .leading)
                            Text(pair.1)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }
}

/// Live list of captured WebSocket frames, colored by direction (M1.1 WS).
private struct WebSocketMessagesView: View {
    let flow: Flow

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Messages").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(flow.webSocketMessages.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            Divider()
            if flow.webSocketMessages.isEmpty {
                EmptyPane(text: "No messages yet")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(flow.webSocketMessages) { message in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: message.direction == .sent
                                      ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                    .foregroundStyle(message.direction == .sent ? .blue : .green)
                                    .font(.system(size: 11))
                                Text(message.kind.rawValue.uppercased())
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 48, alignment: .leading)
                                Text(message.textPreview)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(6)
                                Spacer()
                            }
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 260)
    }
}

/// Shown when the client rejected our certificate — explains why there's no
/// decrypted content and what the user can do.
private struct PinningExplanationView: View {
    let flow: Flow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                    .font(.system(size: 20)).foregroundStyle(.orange)
                Text("Couldn't decrypt \(flow.host)")
                    .font(.system(size: 14, weight: .semibold))
            }

            Text(flow.error ?? "The TLS handshake with the client failed.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Most likely one of:").font(.system(size: 12, weight: .medium))
                bullet("The app pins its certificate and rejects any CA it doesn't ship with. This is expected for banking and hardened apps and can't be bypassed here.")
                bullet("Our CA isn't installed and trusted on the device yet. Install the CA certificate and enable full trust, then retry.")
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct EmptyPane: View {
    let text: String
    var body: some View {
        Text(text).foregroundStyle(.tertiary).font(.caption)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
