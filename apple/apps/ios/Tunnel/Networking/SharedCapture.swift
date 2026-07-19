import Foundation

/// App Group identifier shared by the app and the tunnel extension.
let appGroupID = "group.com.weaver.ios"

/// A captured connection record the extension writes to the App Group and the
/// app reads for display. Iteration 1 captures at the connection level (no
/// decrypt yet); the fields the HTTP inspector needs are filled once MITM lands.
struct TunnelCaptureRecord: Codable, Identifiable {
    var id: UUID
    var startedAt: Date
    var proto: String          // "TCP" | "UDP"
    var host: String           // SNI/HTTP host if known, else the dotted IP
    var destIP: String
    var port: Int
    var bytesUp: Int
    var bytesDown: Int
    var note: String           // e.g. "TLS", "HTTP GET /path", "DNS"
    var closed: Bool
}

/// Rolling, capped store of capture records in the shared App Group container.
/// The extension is the sole writer; the app polls the same file to display.
/// A single JSON file keeps this dependency-free and process-safe enough for a
/// capped, append-mostly log (writes are coordinated + atomic).
final class SharedCaptureStore: @unchecked Sendable {
    static let cap = 500
    private let url: URL
    private let queue = DispatchQueue(label: "com.weaver.capture.store")
    private var records: [TunnelCaptureRecord] = []

    init?() {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
        self.url = container.appendingPathComponent("captures.json")
    }

    func upsert(_ record: TunnelCaptureRecord) {
        queue.async {
            if let i = self.records.firstIndex(where: { $0.id == record.id }) {
                self.records[i] = record
            } else {
                self.records.append(record)
                if self.records.count > Self.cap {
                    self.records.removeFirst(self.records.count - Self.cap)
                }
            }
            self.flush()
        }
    }

    func clear() {
        queue.async {
            self.records.removeAll()
            self.flush()
        }
    }

    private func flush() {
        guard let data = try? JSONEncoder.iso.encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
