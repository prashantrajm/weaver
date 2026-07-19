import Foundation

/// A `Flow` flattened for cross-process transport (tunnel extension → app over
/// the App Group). `Flow` is a reference type with `Data` bodies, so it can't be
/// shared directly; this Codable DTO carries the fields the inspector needs and
/// reconstructs a `Flow` on the app side. Bodies are capped so the shared file
/// stays bounded.
public struct SharedFlowRecord: Codable, Identifiable, Sendable, Equatable {
    public static let bodyCap = 512 * 1024   // 512 KB per body in IPC

    public var id: UUID
    public var startedAt: Date
    public var completedAt: Date?
    public var method: String
    public var urlString: String
    public var scheme: String
    public var host: String
    public var path: String
    public var httpVersion: String
    public var isTLS: Bool
    public var clientDescription: String
    public var statusCode: Int?
    public var error: String?
    public var serverAdvertisedHTTP3: Bool
    public var tlsInterceptionFailed: Bool
    public var bypassed: Bool
    public var requestHeaders: [HTTPHeader]
    public var responseHeaders: [HTTPHeader]
    public var requestBody: Data?
    public var responseBody: Data?

    public init(from flow: Flow) {
        self.id = flow.id
        self.startedAt = flow.startedAt
        self.completedAt = flow.completedAt
        self.method = flow.method
        self.urlString = flow.url.absoluteString
        self.scheme = flow.scheme
        self.host = flow.host
        self.path = flow.path
        self.httpVersion = flow.httpVersion
        self.isTLS = flow.isTLS
        self.clientDescription = flow.clientDescription
        self.statusCode = flow.statusCode
        self.error = flow.error
        self.serverAdvertisedHTTP3 = flow.serverAdvertisedHTTP3
        self.tlsInterceptionFailed = flow.tlsInterceptionFailed
        self.bypassed = flow.bypassed
        self.requestHeaders = flow.requestHeaders
        self.responseHeaders = flow.responseHeaders
        self.requestBody = flow.requestBody.map { $0.prefix(Self.bodyCap) }
        self.responseBody = flow.responseBody.map { $0.prefix(Self.bodyCap) }
    }

    /// Rebuild a `Flow` for display in the inspector.
    public func toFlow() -> Flow {
        let flow = Flow(
            id: id,
            startedAt: startedAt,
            method: method,
            url: URL(string: urlString) ?? URL(string: "https://\(host)\(path)")!,
            scheme: scheme,
            host: host,
            path: path,
            requestHeaders: requestHeaders,
            requestBody: requestBody,
            isTLS: isTLS,
            clientDescription: clientDescription)
        flow.completedAt = completedAt
        flow.httpVersion = httpVersion
        flow.statusCode = statusCode
        flow.error = error
        flow.serverAdvertisedHTTP3 = serverAdvertisedHTTP3
        flow.tlsInterceptionFailed = tlsInterceptionFailed
        flow.bypassed = bypassed
        flow.responseHeaders = responseHeaders
        flow.responseBody = responseBody
        return flow
    }
}
