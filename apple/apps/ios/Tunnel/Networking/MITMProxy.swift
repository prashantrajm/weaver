import Foundation
import os
import WeaverCore

/// Runs the shared `ProxyServer` inside the tunnel extension on loopback. The
/// userspace TCP stack forwards :443 connections to it (via a CONNECT preamble),
/// so it terminates TLS with a leaf minted by the shared CA, decrypts, forwards
/// to the origin, and captures the full HTTP `Flow`. Decrypted flows are written
/// to the App Group for the app to display. Kept intentionally lean (few event
/// loops) because the extension runs under a tight memory budget.
final class MITMProxy: @unchecked Sendable {
    private let log = Logger(subsystem: "com.weaver.ios.tunnel", category: "mitm")
    private let port: UInt16
    private var server: ProxyServer?
    private let flowStore: SharedFlowStore?
    private var handler: FlowHandler?

    /// The loopback port the stack should CONNECT to, or nil if the proxy
    /// couldn't start (no CA yet) — in which case 443 falls back to relay.
    private(set) var listenPort: UInt16?

    init(port: UInt16 = 9099) {
        self.port = port
        self.flowStore = SharedFlowStore()
    }

    /// Load the shared CA and start the proxy. Returns the port on success.
    func start() -> UInt16? {
        guard let caDir = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
                .appendingPathComponent("CA", isDirectory: true),
              let ca = (try? SharedCAStorage.load(from: caDir)) ?? nil else {
            log.error("shared CA not found — open the app once so it can export the CA")
            return nil
        }
        let handler = FlowHandler(store: flowStore)
        self.handler = handler
        let server = ProxyServer(host: "127.0.0.1", port: Int(port), ca: ca,
                                 events: handler, threads: 2)
        do {
            try server.start()
            self.server = server
            self.listenPort = port
            log.log("MITM proxy listening on 127.0.0.1:\(self.port)")
            return port
        } catch {
            log.error("MITM proxy failed to start: \(error.localizedDescription)")
            return nil
        }
    }

    func stop() {
        server?.shutdown()
        server = nil
        listenPort = nil
    }
}

/// Bridges WeaverCore capture events to the shared App Group flow store.
private final class FlowHandler: ProxyEventHandler, @unchecked Sendable {
    private let store: SharedFlowStore?
    init(store: SharedFlowStore?) { self.store = store }

    func flowDidStart(_ flow: Flow) { store?.upsert(SharedFlowRecord(from: flow)) }
    func flowDidComplete(_ flow: Flow) { store?.upsert(SharedFlowRecord(from: flow)) }
    func flowDidUpdate(_ flow: Flow) { store?.upsert(SharedFlowRecord(from: flow)) }
    func proxyDidLog(_ message: String) {}
}

/// Capped, atomic JSON store of decrypted flows in the App Group container.
final class SharedFlowStore: @unchecked Sendable {
    static let cap = 500
    private let url: URL
    private let queue = DispatchQueue(label: "com.weaver.flowstore")
    private var records: [SharedFlowRecord] = []

    init?() {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
        self.url = container.appendingPathComponent("flows.json")
    }

    func upsert(_ record: SharedFlowRecord) {
        queue.async {
            if let i = self.records.firstIndex(where: { $0.id == record.id }) {
                self.records[i] = record
            } else {
                self.records.append(record)
                if self.records.count > Self.cap {
                    self.records.removeFirst(self.records.count - Self.cap)
                }
            }
            if let data = try? JSONEncoder.iso.encode(self.records) {
                try? data.write(to: self.url, options: .atomic)
            }
        }
    }
}
