#if os(iOS)
import Foundation
import Combine

/// App-side view of the connections the tunnel extension captures. The
/// extension is the writer; this polls the shared App Group file and publishes
/// the records for the UI. Connection-level for iteration 1 (the mirror of the
/// extension's `TunnelCaptureRecord`); it fills out into full HTTP flows once
/// MITM decryption lands.
struct TunnelCaptureRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var startedAt: Date
    var proto: String
    var host: String
    var destIP: String
    var port: Int
    var bytesUp: Int
    var bytesDown: Int
    var note: String
    var closed: Bool
}

/// Navigation value for a tunnel connection. Wraps the UUID in its own type so
/// it doesn't collide with the `Flow.ID` (also a UUID) navigation destination
/// used by the in-app-proxy detail screen.
struct TunnelRecordID: Hashable {
    let value: UUID
}

@MainActor
final class TunnelCaptureReader: ObservableObject {
    @Published private(set) var records: [TunnelCaptureRecord] = []

    private let appGroupID = "group.com.weaver.ios"
    private var timer: Timer?
    private var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("captures.json")
    }

    /// Poll the shared file while a view is showing capture data.
    func startPolling() {
        guard timer == nil else { return }
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func reload() {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.tunnelISO.decode([TunnelCaptureRecord].self, from: data) else {
            return
        }
        // Newest first for display.
        let sorted = decoded.sorted { $0.startedAt > $1.startedAt }
        if sorted != records { records = sorted }
    }

    func clear() {
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        records = []
    }
}

private extension JSONDecoder {
    static let tunnelISO: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
#endif
