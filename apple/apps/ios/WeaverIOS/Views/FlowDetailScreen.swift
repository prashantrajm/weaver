#if os(iOS)
import SwiftUI
import WeaverCore
import InspectorKit

/// Per-request detail: a summary header, a Request /
/// Response segment, then segmented sub-tabs (Headers · Query · Body · Raw ·
/// Preview) — collapsible into one scroll. When interception failed or the host
/// was bypassed we explain *why* in plain English instead of showing an empty
/// body (the honest per-flow labeling that's our wedge).
struct FlowDetailScreen: View {
    @EnvironmentObject var store: IOSCaptureStore
    let flowID: Flow.ID

    @State private var side: Side = .response

    enum Side: String, CaseIterable { case request = "Request", response = "Response" }

    private var flow: Flow? { store.flows.first { $0.id == flowID } }

    var body: some View {
        Group {
            if let flow {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        SummaryCard(flow: flow)

                        if flow.bypassed {
                            OpaqueFlowExplainer(
                                icon: "lock.open", tint: .secondary,
                                title: "Tunnelled without decryption",
                                message: flow.error ?? "This host is on the bypass list, so its traffic passed through untouched — the app's own TLS is intact and no plaintext was captured.")
                        } else if flow.tlsInterceptionFailed {
                            PinnedFlowExplainer(flow: flow)
                        } else if flow.isWebSocket {
                            WebSocketSection(flow: flow)
                        } else {
                            Picker("Side", selection: $side) {
                                ForEach(Side.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)

                            MessageSection(
                                headers: side == .request ? flow.requestHeaders : flow.responseHeaders,
                                bodyData: side == .request ? flow.requestBody : flow.responseBody,
                                url: flow.url,
                                contentType: side == .request
                                    ? flow.requestHeaders.first { $0.name.lowercased() == "content-type" }?.value
                                    : flow.contentType)
                        }
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView("Request gone", systemImage: "questionmark",
                                       description: Text("This request was cleared."))
            }
        }
        .navigationTitle(flow?.host ?? "Request")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let flow {
                    ShareLink(item: flow.url.absoluteString) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
    }
}

/// Method · status · URL, on a glass card.
private struct SummaryCard: View {
    let flow: Flow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(flow.method)
                    .font(.caption.weight(.bold).monospaced())
                    .foregroundStyle(FlowPresentation.methodColor(flow.method))
                if let code = flow.statusCode {
                    Text("\(code)")
                        .font(.caption.weight(.bold).monospaced())
                        .foregroundStyle(FlowPresentation.statusCodeColor(code))
                }
                Spacer()
                Label(FlowPresentation.protoLabel(flow), systemImage: flow.isTLS ? "lock.fill" : "lock.open")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(flow.url.absoluteString)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                if let ms = flow.durationMS {
                    metric("Duration", String(format: "%.0f ms", ms))
                }
                metric("Size", FlowPresentation.byteString(flow.responseSize))
                metric("Client", FlowPresentation.clientName(flow))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospaced())
        }
    }
}

/// Headers · Query · Body · Raw · Preview for one side of the exchange.
private struct MessageSection: View {
    let headers: [HTTPHeader]
    let bodyData: Data?
    let url: URL
    let contentType: String?

    enum Tab: String, CaseIterable { case headers = "Headers", query = "Query", body = "Body", raw = "Raw", preview = "Preview" }
    @State private var tab: Tab = .body

    private var queryItems: [(String, String)] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .map { ($0.name, $0.value ?? "") } ?? []
    }

    private var tabs: [Tab] {
        var t: [Tab] = [.headers, .query, .body, .raw]
        if BodyRenderer.isImage(contentType), let d = bodyData, !d.isEmpty { t.append(.preview) }
        return t
    }

    private var active: Tab { tabs.contains(tab) ? tab : .headers }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Tab", selection: $tab) {
                ForEach(tabs, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch active {
            case .headers: KeyValueCard(pairs: headers.map { ($0.name, $0.value) })
            case .query: KeyValueCard(pairs: queryItems)
            case .body: BodyCard(data: bodyData, contentType: contentType, raw: false)
            case .raw: BodyCard(data: bodyData, contentType: contentType, raw: true)
            case .preview: ImagePreviewCard(data: bodyData)
            }
        }
    }
}

private struct KeyValueCard: View {
    let pairs: [(String, String)]
    var body: some View {
        if pairs.isEmpty {
            EmptyCard(text: "None")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pair.0)
                            .font(.caption.weight(.semibold).monospaced())
                            .foregroundStyle(.secondary)
                        Text(pair.1)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    if index < pairs.count - 1 { Divider() }
                }
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
    }
}

private struct BodyCard: View {
    let data: Data?
    let contentType: String?
    let raw: Bool

    var body: some View {
        if let data, !data.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                let text = BodyRenderer.text(data, contentType: contentType, raw: raw)
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = text
                }
                .font(.caption)
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            EmptyCard(text: "No body")
        }
    }
}

private struct ImagePreviewCard: View {
    let data: Data?
    var body: some View {
        if let data, let image = BodyRenderer.image(from: data) {
            VStack(spacing: 6) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                Text("\(Int(image.size.width))×\(Int(image.size.height)) · \(FlowPresentation.byteString(data.count))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            EmptyCard(text: "Not a previewable image")
        }
    }
}

private struct WebSocketSection: View {
    let flow: Flow
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("^[\(flow.webSocketMessages.count) message](inflect: true)")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if flow.webSocketMessages.isEmpty {
                EmptyCard(text: "No messages yet")
            } else {
                ForEach(flow.webSocketMessages) { message in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: message.direction == .sent ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .foregroundStyle(message.direction == .sent ? .blue : .green)
                        Text(message.textPreview)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

private struct PinnedFlowExplainer: View {
    let flow: Flow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Couldn't decrypt \(flow.host)", systemImage: "lock.trianglebadge.exclamationmark.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(flow.error ?? "The TLS handshake with the client failed.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Most likely one of:").font(.subheadline.weight(.medium))
                bullet("The app pins its certificate and rejects any CA it doesn't ship with. Expected for banking and hardened apps — it can't be bypassed here.")
                bullet("Our CA isn't fully trusted on this device yet. Open the Certificate tab and finish setup, then retry.")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 18))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OpaqueFlowExplainer: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(tint)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

private struct EmptyCard: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 60)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}
#endif
