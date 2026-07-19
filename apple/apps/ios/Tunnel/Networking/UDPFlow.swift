import Foundation
import Network

/// One userspace UDP association (mostly DNS and QUIC). We can't decrypt QUIC —
/// it's part of the honest ceiling — but we must relay UDP so DNS and QUIC keep
/// working while the tunnel is up. Datagrams to the destination go out an
/// `NWConnection`; replies are written back to the client as UDP packets.
final class UDPFlow: @unchecked Sendable {
    let key: FlowKey
    private let queue: DispatchQueue
    private let writePacket: (Data) -> Void
    private let onRecord: (TunnelCaptureRecord) -> Void
    private let onClose: (FlowKey) -> Void
    private var conn: NWConnection?
    private var record: TunnelCaptureRecord
    private var idleTimer: DispatchSourceTimer?

    init(key: FlowKey, queue: DispatchQueue,
         writePacket: @escaping (Data) -> Void,
         onRecord: @escaping (TunnelCaptureRecord) -> Void,
         onClose: @escaping (FlowKey) -> Void) {
        self.key = key
        self.queue = queue
        self.writePacket = writePacket
        self.onRecord = onRecord
        self.onClose = onClose
        self.record = TunnelCaptureRecord(
            id: UUID(), startedAt: Date(), proto: "UDP",
            host: key.destDotted, destIP: key.destDotted, port: Int(key.destPort),
            bytesUp: 0, bytesDown: 0,
            note: key.destPort == 53 ? "DNS" : (key.destPort == 443 ? "QUIC" : "UDP"),
            closed: false)
        open()
    }

    private func open() {
        guard let port = NWEndpoint.Port(rawValue: key.destPort) else { return }
        let c = NWConnection(host: NWEndpoint.Host(key.destDotted), port: port, using: .udp)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            self.queue.async { if case .ready = st { self.receive() } }
        }
        c.start(queue: queue)
    }

    func send(_ payload: Data) {
        record.bytesUp += payload.count
        conn?.send(content: payload, completion: .contentProcessed { _ in })
        onRecord(record)
        resetIdle()
    }

    private func receive() {
        conn?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            self.queue.async {
                if let data, !data.isEmpty {
                    self.record.bytesDown += data.count
                    let pkt = UDPDatagram.buildPacket(
                        source: self.key.dest, destination: self.key.source,
                        sourcePort: self.key.destPort, destPort: self.key.sourcePort, payload: data)
                    self.writePacket(pkt)
                    self.onRecord(self.record)
                }
                if error == nil { self.receive() } else { self.close() }
            }
        }
    }

    private func resetIdle() {
        idleTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 30)
        t.setEventHandler { [weak self] in self?.close() }
        t.resume()
        idleTimer = t
    }

    func close() {
        idleTimer?.cancel(); idleTimer = nil
        conn?.cancel(); conn = nil
        record.closed = true
        onRecord(record)
        onClose(key)
    }
}
