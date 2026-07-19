import Foundation

/// Minimal IPv4 + TCP/UDP packet parsing and building for the userspace stack.
/// Only what the tunnel needs: read the tuple + payload from packets iOS hands
/// us, and craft valid response packets (correct header + checksums) to write
/// back. IPv6 is intentionally not routed into the tunnel (see the provider),
/// so this is IPv4-only by design.
enum IPProto: UInt8 {
    case tcp = 6
    case udp = 17
}

/// A parsed IPv4 packet: header fields plus a slice pointing at the L4 payload.
struct IPv4Packet {
    var source: UInt32
    var destination: UInt32
    var proto: UInt8
    var payload: Data          // TCP/UDP segment (header + data)
    var ihl: Int               // IP header length in bytes

    init?(_ data: Data) {
        guard data.count >= 20 else { return nil }
        let b = [UInt8](data)
        let version = b[0] >> 4
        guard version == 4 else { return nil }
        let ihl = Int(b[0] & 0x0f) * 4
        guard ihl >= 20, data.count >= ihl else { return nil }
        let totalLength = Int(b[2]) << 8 | Int(b[3])
        let end = min(max(totalLength, ihl), data.count)
        self.ihl = ihl
        self.proto = b[9]
        self.source = UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15])
        self.destination = UInt32(b[16]) << 24 | UInt32(b[17]) << 16 | UInt32(b[18]) << 8 | UInt32(b[19])
        self.payload = data.subdata(in: ihl..<end)
    }

    /// Build an IPv4 packet carrying `payload` from `src` to `dst`.
    static func build(source: UInt32, destination: UInt32, proto: UInt8, payload: Data) -> Data {
        var h = [UInt8](repeating: 0, count: 20)
        h[0] = 0x45                               // v4, IHL 5
        let total = 20 + payload.count
        h[2] = UInt8(total >> 8); h[3] = UInt8(total & 0xff)
        h[6] = 0x40                               // don't fragment
        h[8] = 64                                 // TTL
        h[9] = proto
        h[12] = UInt8(source >> 24); h[13] = UInt8((source >> 16) & 0xff)
        h[14] = UInt8((source >> 8) & 0xff); h[15] = UInt8(source & 0xff)
        h[16] = UInt8(destination >> 24); h[17] = UInt8((destination >> 16) & 0xff)
        h[18] = UInt8((destination >> 8) & 0xff); h[19] = UInt8(destination & 0xff)
        let cs = Checksum.ones(h)
        h[10] = UInt8(cs >> 8); h[11] = UInt8(cs & 0xff)
        var out = Data(h)
        out.append(payload)
        return out
    }
}

/// A parsed TCP segment over an IPv4 packet.
struct TCPSegment {
    var sourcePort: UInt16
    var destPort: UInt16
    var seq: UInt32
    var ack: UInt32
    var flags: UInt8            // bit0 FIN, 1 SYN, 2 RST, 3 PSH, 4 ACK
    var window: UInt16
    var payload: Data
    var dataOffset: Int

    var isSYN: Bool { flags & 0x02 != 0 }
    var isACK: Bool { flags & 0x10 != 0 }
    var isFIN: Bool { flags & 0x01 != 0 }
    var isRST: Bool { flags & 0x04 != 0 }

    init?(_ data: Data) {
        guard data.count >= 20 else { return nil }
        let b = [UInt8](data)
        self.sourcePort = UInt16(b[0]) << 8 | UInt16(b[1])
        self.destPort = UInt16(b[2]) << 8 | UInt16(b[3])
        self.seq = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        self.ack = UInt32(b[8]) << 24 | UInt32(b[9]) << 16 | UInt32(b[10]) << 8 | UInt32(b[11])
        let off = Int(b[12] >> 4) * 4
        guard off >= 20, data.count >= off else { return nil }
        self.dataOffset = off
        self.flags = b[13]
        self.window = UInt16(b[14]) << 8 | UInt16(b[15])
        self.payload = data.subdata(in: off..<data.count)
    }

    /// Build a TCP segment + wrap it in an IPv4 packet (checksums computed over
    /// the pseudo-header, as required).
    static func buildPacket(source: UInt32, destination: UInt32,
                            sourcePort: UInt16, destPort: UInt16,
                            seq: UInt32, ack: UInt32, flags: UInt8,
                            window: UInt16, payload: Data = Data()) -> Data {
        var t = [UInt8](repeating: 0, count: 20)
        t[0] = UInt8(sourcePort >> 8); t[1] = UInt8(sourcePort & 0xff)
        t[2] = UInt8(destPort >> 8); t[3] = UInt8(destPort & 0xff)
        t[4] = UInt8(seq >> 24); t[5] = UInt8((seq >> 16) & 0xff)
        t[6] = UInt8((seq >> 8) & 0xff); t[7] = UInt8(seq & 0xff)
        t[8] = UInt8(ack >> 24); t[9] = UInt8((ack >> 16) & 0xff)
        t[10] = UInt8((ack >> 8) & 0xff); t[11] = UInt8(ack & 0xff)
        t[12] = 0x50                              // data offset 5 words
        t[13] = flags
        t[14] = UInt8(window >> 8); t[15] = UInt8(window & 0xff)
        var seg = Data(t)
        seg.append(payload)
        let cs = Checksum.tcp(source: source, destination: destination,
                              proto: IPProto.tcp.rawValue, segment: seg)
        seg[16] = UInt8(cs >> 8); seg[17] = UInt8(cs & 0xff)
        return IPv4Packet.build(source: source, destination: destination,
                                proto: IPProto.tcp.rawValue, payload: seg)
    }
}

/// A parsed UDP datagram over an IPv4 packet.
struct UDPDatagram {
    var sourcePort: UInt16
    var destPort: UInt16
    var payload: Data

    init?(_ data: Data) {
        guard data.count >= 8 else { return nil }
        let b = [UInt8](data)
        self.sourcePort = UInt16(b[0]) << 8 | UInt16(b[1])
        self.destPort = UInt16(b[2]) << 8 | UInt16(b[3])
        self.payload = data.subdata(in: 8..<data.count)
    }

    static func buildPacket(source: UInt32, destination: UInt32,
                            sourcePort: UInt16, destPort: UInt16, payload: Data) -> Data {
        let length = 8 + payload.count
        var u = [UInt8](repeating: 0, count: 8)
        u[0] = UInt8(sourcePort >> 8); u[1] = UInt8(sourcePort & 0xff)
        u[2] = UInt8(destPort >> 8); u[3] = UInt8(destPort & 0xff)
        u[4] = UInt8(length >> 8); u[5] = UInt8(length & 0xff)
        var seg = Data(u)
        seg.append(payload)
        let cs = Checksum.tcp(source: source, destination: destination,
                              proto: IPProto.udp.rawValue, segment: seg)
        // UDP checksum 0 means "not computed"; keep the real one but 0 → 0xffff.
        let final = cs == 0 ? 0xffff : cs
        seg[6] = UInt8(final >> 8); seg[7] = UInt8(final & 0xff)
        return IPv4Packet.build(source: source, destination: destination,
                                proto: IPProto.udp.rawValue, payload: seg)
    }
}

enum Checksum {
    /// One's-complement sum over bytes (IP header / generic).
    static func ones(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return UInt16(~sum & 0xffff)
    }

    /// TCP/UDP checksum with the IPv4 pseudo-header.
    static func tcp(source: UInt32, destination: UInt32, proto: UInt8, segment: Data) -> UInt16 {
        var pseudo = [UInt8]()
        pseudo.append(contentsOf: [UInt8(source >> 24), UInt8((source >> 16) & 0xff),
                                   UInt8((source >> 8) & 0xff), UInt8(source & 0xff)])
        pseudo.append(contentsOf: [UInt8(destination >> 24), UInt8((destination >> 16) & 0xff),
                                   UInt8((destination >> 8) & 0xff), UInt8(destination & 0xff)])
        pseudo.append(0)
        pseudo.append(proto)
        pseudo.append(UInt8(segment.count >> 8))
        pseudo.append(UInt8(segment.count & 0xff))
        pseudo.append(contentsOf: [UInt8](segment))
        return ones(pseudo)
    }
}
