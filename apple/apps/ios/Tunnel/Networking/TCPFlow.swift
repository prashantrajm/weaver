import Foundation
import Network

/// One userspace TCP connection. It terminates the client's TCP locally (SYN /
/// SYN-ACK / ACK, sequence tracking, FIN/RST) and moves the byte stream to an
/// upstream `NWConnection`. Two upstream modes:
///
///  - **direct**: connect straight to the real destination (transparent relay).
///    Used for non-443 traffic and as a fallback when we can't read an SNI.
///  - **mitm**: connect to the in-extension `ProxyServer` on loopback and send a
///    `CONNECT <sni>:443` preamble, so the proxy terminates TLS with a minted
///    leaf and decrypts the exchange. Used for 443 once we sniff the SNI.
///
/// Happy-path only for now (in-order segments, no loss recovery), which covers
/// the overwhelming majority of on-device connections.
final class TCPFlow: @unchecked Sendable {
    let key: FlowKey
    private let queue: DispatchQueue
    private let writePacket: (Data) -> Void
    private let onRecord: (TunnelCaptureRecord) -> Void
    private let onClose: (FlowKey) -> Void
    private let mitmProxyPort: UInt16?     // nil → always direct

    private var conn: NWConnection?
    private var state: State = .idle
    private var rcvNext: UInt32 = 0
    private var sndNext: UInt32 = 0
    private var record: TunnelCaptureRecord

    private enum State { case idle, synReceived, established, closing, closed }
    private enum Upstream { case undecided, direct, mitm }
    private var upstream: Upstream
    private var upstreamReady = false       // NWConnection is .ready
    private var connectAcked = false        // MITM: CONNECT 200 consumed
    private var pendingUp = Data()          // client bytes queued until upstream is usable
    private var connectRespBuf = Data()     // MITM: accumulates the CONNECT response

    init(key: FlowKey, syn: TCPSegment, queue: DispatchQueue, mitmProxyPort: UInt16?,
         writePacket: @escaping (Data) -> Void,
         onRecord: @escaping (TunnelCaptureRecord) -> Void,
         onClose: @escaping (FlowKey) -> Void) {
        self.key = key
        self.queue = queue
        self.mitmProxyPort = mitmProxyPort
        self.writePacket = writePacket
        self.onRecord = onRecord
        self.onClose = onClose
        // 443 with a proxy available → decide direct-vs-mitm once we see the SNI.
        self.upstream = (key.destPort == 443 && mitmProxyPort != nil) ? .undecided : .direct
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
            if upstream == .direct { openDirect() }   // MITM defers until SNI
            sendFlags(0x12)                            // SYN|ACK
            sndNext = sndNext &+ 1
            state = .synReceived
            emit()

        case .synReceived where seg.isACK && !seg.isSYN:
            state = .established
            deliverIfData(seg)

        case .established:
            if seg.isRST { teardown(); return }
            if seg.isFIN {
                rcvNext = rcvNext &+ 1
                sendFlags(0x10)
                conn?.send(content: nil, isComplete: true, completion: .idempotent)
                sendFlags(0x11)
                sndNext = sndNext &+ 1
                state = .closing
                return
            }
            deliverIfData(seg)

        default:
            if seg.isRST { teardown() }
        }
    }

    private func deliverIfData(_ seg: TCPSegment) {
        guard !seg.payload.isEmpty else { return }
        guard seg.seq == rcvNext else { return }   // in-order only
        rcvNext = rcvNext &+ UInt32(seg.payload.count)
        record.bytesUp += seg.payload.count
        sniffHost(seg.payload)
        if upstream == .undecided {
            decideUpstream(with: seg.payload)      // buffers into pendingUp itself
        } else {
            sendUpstream(seg.payload)
        }
        sendFlags(0x10)                            // ACK
        emit()
    }

    // MARK: - Upstream selection

    /// First client bytes on a 443 flow: read the SNI to pick MITM, or fall back
    /// to a direct relay if there's no readable SNI (non-TLS or split hello).
    /// Client bytes always accumulate in `pendingUp` until an upstream is chosen
    /// and usable, then `flushPending` sends them in order.
    private func decideUpstream(with payload: Data) {
        pendingUp.append(payload)
        if let sni = TLSClientHello.serverName(from: pendingUp) {
            record.host = sni; record.note = "HTTPS " + sni
            upstream = .mitm
            openMITM(sni: sni)
        } else if pendingUp.count > 4096 {
            upstream = .direct                    // give up sniffing; relay directly
            openDirect()
        }
        // else: keep buffering; a later segment may complete the ClientHello.
    }

    /// Queue client bytes once an upstream is chosen. They buffer in `pendingUp`
    /// until the upstream is usable (connected, and for MITM the CONNECT acked),
    /// then flush in order.
    private func sendUpstream(_ payload: Data) {
        let usable = (upstream == .direct && upstreamReady) || (upstream == .mitm && connectAcked)
        if usable {
            conn?.send(content: payload, completion: .contentProcessed { _ in })
        } else {
            pendingUp.append(payload)
        }
    }

    private func openDirect() {
        guard conn == nil else { return }
        openConnection(host: key.destDotted, port: key.destPort)
    }

    private func openMITM(sni: String) {
        guard let proxyPort = mitmProxyPort else { openDirect(); return }
        openConnection(host: "127.0.0.1", port: proxyPort)
        // The CONNECT line is sent once the connection is .ready.
        pendingConnectHost = "\(sni):\(key.destPort)"
    }

    private var pendingConnectHost: String?

    private func openConnection(host: String, port: UInt16) {
        guard let p = NWEndpoint.Port(rawValue: port) else { teardown(); return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        self.conn = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            self.queue.async {
                switch st {
                case .ready: self.upstreamDidBecomeReady()
                case .failed, .cancelled: self.teardownFromUpstream()
                default: break
                }
            }
        }
        c.start(queue: queue)
    }

    private func upstreamDidBecomeReady() {
        upstreamReady = true
        if let connectHost = pendingConnectHost {
            // MITM: send CONNECT, then wait for the 200 before flushing client bytes.
            let line = "CONNECT \(connectHost) HTTP/1.1\r\nHost: \(connectHost)\r\n\r\n"
            conn?.send(content: Data(line.utf8), completion: .contentProcessed { _ in })
            receiveUpstream()
        } else {
            // Direct: flush anything buffered and start relaying.
            flushPending()
            receiveUpstream()
        }
    }

    private func flushPending() {
        guard !pendingUp.isEmpty else { return }
        conn?.send(content: pendingUp, completion: .contentProcessed { _ in })
        pendingUp.removeAll()
    }

    // MARK: - Upstream → client

    private func receiveUpstream() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            self.queue.async {
                if let data, !data.isEmpty { self.handleUpstreamData(data) }
                if done || error != nil {
                    self.sendFlags(0x11)          // FIN|ACK
                    self.sndNext = self.sndNext &+ 1
                    self.finish()
                } else {
                    self.receiveUpstream()
                }
            }
        }
    }

    private func handleUpstreamData(_ data: Data) {
        if upstream == .mitm && !connectAcked {
            connectRespBuf.append(data)
            guard let range = connectRespBuf.range(of: Data("\r\n\r\n".utf8)) else { return }
            connectAcked = true
            let remainder = connectRespBuf.suffix(from: range.upperBound)
            connectRespBuf.removeAll()
            flushPending()                        // send the buffered ClientHello to the proxy
            if !remainder.isEmpty { deliverDown(Data(remainder)) }
            return
        }
        deliverDown(data)
    }

    private func deliverDown(_ data: Data) {
        record.bytesDown += data.count
        sendData(data)
        emit()
    }

    // MARK: - Emit packets to the client

    private func sendFlags(_ flags: UInt8) {
        writePacket(TCPSegment.buildPacket(
            source: key.dest, destination: key.source,
            sourcePort: key.destPort, destPort: key.sourcePort,
            seq: sndNext, ack: rcvNext, flags: flags, window: 0xffff))
    }

    private func sendData(_ data: Data) {
        let mss = 1400
        var offset = 0
        while offset < data.count {
            let chunk = data.subdata(in: offset..<min(offset + mss, data.count))
            writePacket(TCPSegment.buildPacket(
                source: key.dest, destination: key.source,
                sourcePort: key.destPort, destPort: key.sourcePort,
                seq: sndNext, ack: rcvNext, flags: 0x18, window: 0xffff, payload: chunk))
            sndNext = sndNext &+ UInt32(chunk.count)
            offset += chunk.count
        }
    }

    // MARK: - Host sniffing (for :80; :443 handled in decideUpstream)

    private func sniffHost(_ payload: Data) {
        guard key.destPort == 80, record.note == "HTTP" || record.note.hasPrefix("HTTP") else { return }
        if let line = httpRequestLine(payload) {
            record.host = line.host ?? record.host
            record.note = "HTTP " + line.summary
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

    private func teardown() { conn?.cancel(); conn = nil; finish() }

    private func teardownFromUpstream() {
        sendFlags(0x14)   // RST|ACK
        finish()
    }

    func close() { teardown() }
}
