import SwiftUI
import WeaverCore
import UniformTypeIdentifiers

/// Exports captured flows as an HTTP Archive (HAR 1.2) file (M1.5). HAR is the
/// interchange format browser devtools and other debugging proxies read, so sessions move
/// cleanly between tools. Shared by both Apple apps.
public struct HARDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.json] }

    public let flows: [Flow]

    public init(flows: [Flow]) { self.flows = flows }

    public init(configuration: ReadConfiguration) throws {
        self.flows = []   // import not supported yet
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let har = Self.buildHAR(flows: flows)
        let data = try JSONSerialization.data(withJSONObject: har, options: [.prettyPrinted])
        return FileWrapper(regularFileWithContents: data)
    }

    public static func buildHAR(flows: [Flow]) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let entries: [[String: Any]] = flows.map { flow in
            var entry: [String: Any] = [
                "startedDateTime": iso.string(from: flow.startedAt),
                "time": flow.durationMS ?? 0,
                "request": [
                    "method": flow.method,
                    "url": flow.url.absoluteString,
                    "httpVersion": "HTTP/1.1",
                    "headers": flow.requestHeaders.map { ["name": $0.name, "value": $0.value] },
                    "queryString": queryString(flow.url),
                    "headersSize": -1,
                    "bodySize": flow.requestSize,
                    "postData": postData(body: flow.requestBody, headers: flow.requestHeaders),
                ].compactMapValues { $0 },
                "response": [
                    "status": flow.statusCode ?? 0,
                    "statusText": "",
                    "httpVersion": "HTTP/1.1",
                    "headers": flow.responseHeaders.map { ["name": $0.name, "value": $0.value] },
                    "content": [
                        "size": flow.responseSize,
                        "mimeType": flow.contentType ?? "application/octet-stream",
                        "text": flow.responseBody.flatMap { String(data: $0, encoding: .utf8) } ?? "",
                    ],
                    "redirectURL": "",
                    "headersSize": -1,
                    "bodySize": flow.responseSize,
                ],
                "cache": [:],
                "timings": ["send": 0, "wait": flow.durationMS ?? 0, "receive": 0],
            ]
            entry["serverIPAddress"] = flow.host
            return entry
        }
        return [
            "log": [
                "version": "1.2",
                "creator": ["name": "Weaver", "version": "0.1"],
                "entries": entries,
            ]
        ]
    }

    private static func queryString(_ url: URL) -> [[String: String]] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .map { ["name": $0.name, "value": $0.value ?? ""] } ?? []
    }

    private static func postData(body: Data?, headers: [HTTPHeader]) -> [String: Any]? {
        guard let body, !body.isEmpty else { return nil }
        let mime = headers.first { $0.name.lowercased() == "content-type" }?.value ?? "application/octet-stream"
        return [
            "mimeType": mime,
            "text": String(data: body, encoding: .utf8) ?? "",
        ]
    }
}
