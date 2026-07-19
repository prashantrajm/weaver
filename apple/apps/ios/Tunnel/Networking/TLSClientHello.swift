import Foundation

/// Extracts the SNI host name from a TLS ClientHello so a :443 connection can be
/// labelled by hostname (and, later, MITM'd with a leaf minted for that name)
/// even though the packet only carries the destination IP. Best-effort: returns
/// nil for non-TLS bytes or a split ClientHello we can't parse yet.
enum TLSClientHello {
    static func serverName(from data: Data) -> String? {
        let b = [UInt8](data)
        guard b.count > 43, b[0] == 0x16 else { return nil }  // handshake record
        // record: type(1) version(2) length(2) then handshake
        var p = 5
        guard p < b.count, b[p] == 0x01 else { return nil }   // ClientHello
        p += 4                                                  // hs type(1)+len(3)
        p += 2                                                  // client version
        p += 32                                                 // random
        guard p < b.count else { return nil }
        let sessionIDLen = Int(b[p]); p += 1 + sessionIDLen
        guard p + 2 <= b.count else { return nil }
        let cipherLen = Int(b[p]) << 8 | Int(b[p + 1]); p += 2 + cipherLen
        guard p < b.count else { return nil }
        let compLen = Int(b[p]); p += 1 + compLen
        guard p + 2 <= b.count else { return nil }
        let extTotal = Int(b[p]) << 8 | Int(b[p + 1]); p += 2
        let extEnd = min(p + extTotal, b.count)
        while p + 4 <= extEnd {
            let type = Int(b[p]) << 8 | Int(b[p + 1])
            let len = Int(b[p + 2]) << 8 | Int(b[p + 3])
            p += 4
            guard p + len <= b.count else { return nil }
            if type == 0x0000 {   // server_name
                // server_name_list(2) then entry: type(1) len(2) name
                guard p + 5 <= b.count else { return nil }
                let nameLen = Int(b[p + 3]) << 8 | Int(b[p + 4])
                let start = p + 5
                guard start + nameLen <= b.count else { return nil }
                return String(bytes: b[start..<start + nameLen], encoding: .utf8)
            }
            p += len
        }
        return nil
    }
}
