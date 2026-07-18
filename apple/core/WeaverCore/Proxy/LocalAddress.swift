import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Discovers the Mac's LAN IPv4 address so the UI can tell the user what to
/// enter as the HTTP proxy on their phone. The proxy binds all interfaces
/// (`0.0.0.0`); this is only for display/configuration.
public enum LocalAddress {

    /// Best LAN IPv4 for reaching this Mac from another device on the same
    /// network. Prefers Wi-Fi (`en0`) / Ethernet (`en1`), skips loopback and
    /// link-local (169.254.x). Returns nil if only loopback is available.
    public static func primaryIPv4() -> String? {
        var candidates: [(iface: String, ip: String)] = []

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }

            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: current.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                     &host, socklen_t(host.count),
                                     nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254.") else { continue } // link-local

            candidates.append((name, ip))
        }

        // Prefer the conventional Wi-Fi/Ethernet interfaces, else first found.
        let preferredOrder = ["en0", "en1", "en2"]
        for iface in preferredOrder {
            if let match = candidates.first(where: { $0.iface == iface }) {
                return match.ip
            }
        }
        return candidates.first?.ip
    }
}
