import Foundation
import os

/// Identifies a connection by its IPv4 4-tuple.
struct FlowKey: Hashable {
    let source: UInt32
    let sourcePort: UInt16
    let dest: UInt32
    let destPort: UInt16

    var destDotted: String {
        "\((dest >> 24) & 0xff).\((dest >> 16) & 0xff).\((dest >> 8) & 0xff).\(dest & 0xff)"
    }
}

/// Demultiplexes raw IPv4 packets from the tunnel to per-connection TCP/UDP
/// flows, and funnels the flows' capture records to the shared App Group store.
/// All flow state is confined to one serial queue, so the flows themselves need
/// no additional locking.
final class TunnelStack {
    private let queue = DispatchQueue(label: "com.weaver.tunnel.stack")
    private let writePacket: (Data) -> Void
    private let store: SharedCaptureStore?
    private let log = Logger(subsystem: "com.weaver.ios.tunnel", category: "stack")

    private var tcp: [FlowKey: TCPFlow] = [:]
    private var udp: [FlowKey: UDPFlow] = [:]

    init(writePacket: @escaping (Data) -> Void, store: SharedCaptureStore?) {
        self.writePacket = writePacket
        self.store = store
    }

    /// Called for each IP packet iOS hands us from the tunnel.
    func input(_ packet: Data) {
        queue.async { self.route(packet) }
    }

    private func route(_ packet: Data) {
        guard let ip = IPv4Packet(packet) else { return }
        switch ip.proto {
        case IPProto.tcp.rawValue:
            guard let seg = TCPSegment(ip.payload) else { return }
            let key = FlowKey(source: ip.source, sourcePort: seg.sourcePort,
                              dest: ip.destination, destPort: seg.destPort)
            if let flow = tcp[key] {
                flow.handle(seg)
            } else if seg.isSYN && !seg.isACK {
                let flow = TCPFlow(key: key, syn: seg, queue: queue,
                                   writePacket: writePacket,
                                   onRecord: { [weak self] in self?.store?.upsert($0) },
                                   onClose: { [weak self] k in self?.tcp[k] = nil })
                tcp[key] = flow
                flow.handle(seg)
            }
            // Non-SYN for an unknown flow: ignore (no RST flood in iteration 1).

        case IPProto.udp.rawValue:
            guard let dg = UDPDatagram(ip.payload) else { return }
            let key = FlowKey(source: ip.source, sourcePort: dg.sourcePort,
                              dest: ip.destination, destPort: dg.destPort)
            let flow = udp[key] ?? {
                let f = UDPFlow(key: key, queue: queue, writePacket: writePacket,
                                onRecord: { [weak self] in self?.store?.upsert($0) },
                                onClose: { [weak self] k in self?.udp[k] = nil })
                udp[key] = f
                return f
            }()
            flow.send(dg.payload)

        default:
            break   // ICMP etc.: not handled in iteration 1
        }
    }

    func shutdown() {
        queue.async {
            self.tcp.values.forEach { $0.close() }
            self.udp.values.forEach { $0.close() }
            self.tcp.removeAll(); self.udp.removeAll()
        }
    }
}
