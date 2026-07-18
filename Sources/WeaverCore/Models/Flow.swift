import Foundation

/// A single captured request/response exchange. This is the central data model
/// shared across the inspector UI, session persistence, and (later) the iOS/
/// Android ports. Reference-type so live updates (response arriving after the
/// request) mutate in place while the UI observes it.
public final class Flow: Identifiable, @unchecked Sendable {
    public let id: UUID
    public let startedAt: Date

    // Request
    public let method: String
    public let url: URL
    public let scheme: String
    public let host: String
    public let path: String
    public var requestHeaders: [HTTPHeader]
    public var requestBody: Data?

    // Response (populated when it arrives)
    public var statusCode: Int?
    public var responseHeaders: [HTTPHeader]
    public var responseBody: Data?
    public var completedAt: Date?

    // Metadata
    public var clientDescription: String   // best-effort client/app identity
    public var isTLS: Bool
    public var error: String?

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        method: String,
        url: URL,
        scheme: String,
        host: String,
        path: String,
        requestHeaders: [HTTPHeader] = [],
        requestBody: Data? = nil,
        isTLS: Bool,
        clientDescription: String = ""
    ) {
        self.id = id
        self.startedAt = startedAt
        self.method = method
        self.url = url
        self.scheme = scheme
        self.host = host
        self.path = path
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.responseHeaders = []
        self.isTLS = isTLS
        self.clientDescription = clientDescription
    }

    public var durationMS: Double? {
        guard let completedAt else { return nil }
        return completedAt.timeIntervalSince(startedAt) * 1000
    }

    public var responseSize: Int { responseBody?.count ?? 0 }
    public var requestSize: Int { requestBody?.count ?? 0 }

    public var contentType: String? {
        responseHeaders.first { $0.name.lowercased() == "content-type" }?.value
    }

    /// Coarse classification used by the type-filter tabs.
    public var kind: FlowKind {
        if isTLS && scheme == "https" { /* fallthrough to content classification */ }
        guard let ct = contentType?.lowercased() else {
            return isTLS ? .https : .http
        }
        if ct.contains("json") { return .json }
        if ct.contains("xml") { return .xml }
        if ct.contains("x-www-form-urlencoded") || ct.contains("multipart/form") { return .form }
        if ct.contains("javascript") { return .js }
        if ct.contains("css") { return .css }
        if ct.contains("html") { return .document }
        if ct.contains("image") || ct.contains("video") || ct.contains("audio") { return .media }
        return isTLS ? .https : .http
    }
}

public struct HTTPHeader: Hashable, Sendable, Codable {
    public let name: String
    public let value: String
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public enum FlowKind: String, CaseIterable, Sendable {
    case http = "HTTP"
    case https = "HTTPS"
    case json = "JSON"
    case form = "Form"
    case xml = "XML"
    case js = "JS"
    case css = "CSS"
    case document = "Document"
    case media = "Media"
    case other = "Other"
}
