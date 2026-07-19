import Foundation
import Network

/// One userspace TCP connection: it terminates the client's TCP locally (SYN /
/// SYN-ACK / ACK, sequence tracking, FIN/RST) and relays the byte stream to the
/// real destination over an `NWConnection` — a transparent proxy. Iteration 1
/// handles the happy path (in-order segments, no retransmission), which covers
/// the overwhelming majority of on-device connections; loss-recovery and
/// window management are follow-ups. Decryption (MITM) replaces the plain relay
/// in the next increment; here we still capture the connection + its host.
final class TCPFlow: @unchecked Sendable {
    let key: FlowKey
    private let queue: DispatchQueue
    private let writePacket: (Data) -> Void
    private let onRecord: (TunnelCaptureRecord) -> Void
    private let onClose: (FlowKey) -> Void

    private var conn: NWConnection?
    private var state: State = .idle
    private var rcvNext: UInt32 = 0      // next client seq we expect
    private var sndNext: UInt32 = 0      // our next seq to the client
    private var record: TunnelCaptureRecord
    private var sniffedHost = false

    private enum State { case idle, synReceived, established, closing, closed }

    init(key: FlowKey, syn: TCPSegment, queue: DispatchQueue,
         writePacket: @escaping (Data) -> Void,
         onRecord: @escaping (TunnelCaptureRecord) -> Void,
         onClose: @escaping (FlowKey) -> Void) {
        self.key = key
        self.queue = queue
        self.writePacket = writePacket
        self.onRecord = onRecord
        self.onClose = onClose
        self.record = TunnelCaptureRecord(
            id: UUID(), startedAt: Date(),
            proto: "TCP", host: key.destDotted, destIP: key.destDotted,
            port: Int(key.destPort), bytesUp: 0, bytesDown: 0,
            note: key.destPort == 443 ? "TLS" : (key.destPort == 80 ? "HTTP" : "TCP"),
            closed: false)
    }

    // MARK: - Inbound (from the tunnel / client)

    func handle(_ seg: TCPSegment) {
        switch state {
        case .idle where seg.isSYN:
            rcvNext = seg.seq &+ 1
            sndNext = UInt32.random(in: 1...0x7fffffff)
            openUpstream()
            sendFlags(0x12)                 // SYN|ACK
            sndNext = sndNext &+ 1          // SYN consumes one seq
            state = .synReceived
            emit()

        case .synReceived where seg.isACK && !seg.isSYN:
            state = .established
            deliverIfData(seg)

        case .established:
            if seg.isRST { teardown(); return }
            if seg.isFIN {
                rcvNext = rcvNext &+ 1
                sendFlags(0x10)             // ACK the FIN
                conn?.send(content: nil, isComplete: true, completion: .idempotent)
                sendFlags(0x11)             // our FIN|ACK
                sndNext = sndNext &+ 1
                state = .closing
                return
            }
            deliverIfData(seg)

        default:
            if seg.isRST { teardown() }
        }
    }

    /// Forward in-order client payload to the upstream and ACK it.
    private func deliverIfData(_ seg: TCPSegment) {
        guard !seg.payload.isEmpty else { return }
        guard seg.seq == rcvNext else { return }   // iteration 1: in-order only
        rcvNext = rcvNext &+ UInt32(seg.payload.count)
        record.bytesUp += seg.payload.count
        sniffHost(seg.payload)
        conn?.send(content: seg.payload, completion: .contentProcessed { _ in })
        sendFlags(0x10)                            // ACK
        emit()
    }

    // MARK: - Upstream (to the real destination)

    private func openUpstream() {
        let host = NWEndpoint.Host(key.destDotted)
        guard let port = NWEndpoint.Port(rawValue: key.destPort) else { teardown(); return }
        let c = NWConnection(host: host, port: port, using: .tcp)
        self.conn = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            self.queue.async {
                switch st {
                case .ready: self.receiveUpstream()
                case .failed, .cancelled: self.teardownFromUpstream()
                default: break
                }
            }
        }
        c.start(queue: queue)
    }

    private func receiveUpstream() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            self.queue.async {
                if let data, !data.isEmpty {
                    self.record.bytesDown += data.count
                    self.sendData(data)
                    self.emit()
                }
                if done || error != nil {
                    self.sendFlags(0x11)          // FIN|ACK to client
                    self.sndNext = self.sndNext &+ 1
                    self.finish()
                } else {
                    self.receiveUpstream()
                }
            }
        }
    }

    // MARK: - Emit packets to the client

    private func sendFlags(_ flags: UInt8) {
        let pkt = TCPSegment.buildPacket(
            source: key.dest, destination: key.source,
            sourcePort: key.destPort, destPort: key.sourcePort,
            seq: sndNext, ack: rcvNext, flags: flags, window: 0xffff)
        writePacket(pkt)
    }

    private func sendData(_ data: Data) {
        // Segment to a safe payload size (MTU 1500 − IP/TCP headers).
        let mss = 1400
        var offset = 0
        while offset < data.count {
            let chunk = data.subdata(in: offset..<min(offset + mss, data.count))
            let pkt = TCPSegment.buildPacket(
                source: key.dest, destination: key.source,
                sourcePort: key.destPort, destPort: key.sourcePort,
                seq: sndNext, ack: rcvNext, flags: 0x18, window: 0xffff, payload: chunk)  // PSH|ACK
            writePacket(pkt)
            sndNext = sndNext &+ UInt32(chunk.count)
            offset += chunk.count
        }
    }

    // MARK: - Host sniffing + capture record

    private func sniffHost(_ payload: Data) {
        guard !sniffedHost else { return }
        if key.destPort == 443, let sni = TLSClientHello.serverName(from: payload) {
            record.host = sni; record.note = "TLS " + sni; sniffedHost = true
        } else if key.destPort == 80, let line = httpRequestLine(payload) {
            record.host = line.host ?? record.host
            record.note = "HTTP " + line.summary; sniffedHost = true
        }
    }

    private func httpRequestLine(_ data: Data) -> (summary: String, host: String?)? {
        guard let text = String(data: data.prefix(2048), encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first, first.contains("HTTP/") else { return nil }
        let parts = first.split(separator: " ")
        let summary = parts.count >= 2 ? "\(parts[0]) \(parts[1])" : first
        let host = lines.first { $0.lowercased().hasPrefix("host:") }?
            .split(separator: ":").dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) }
        return (summary, host)
    }

    private func emit() { onRecord(record) }

    // MARK: - Teardown

    private func finish() {
        guard state != .closed else { return }
        state = .closed
        record.closed = true
        emit()
        conn?.cancel(); conn = nil
        onClose(key)
    }

    private func teardown() {
        conn?.cancel(); conn = nil
        finish()
    }

    private func teardownFromUpstream() {
        // Upstream died before/while established: RST the client.
        sendFlags(0x14)   // RST|ACK
        finish()
    }

    func close() { teardown() }
}
