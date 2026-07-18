import Foundation
import NIOHTTP1

/// HTTP/3 (QUIC) handling for v1: **passthrough + label + force TCP**.
///
/// We can't MITM QUIC — it runs over UDP and there's no TLS-terminating QUIC
/// server to slot our leaf into — and as an HTTP proxy we never receive those
/// UDP flows in the first place. What we *can* do is stop clients from silently
/// upgrading to HTTP/3 (which would make their traffic disappear from capture):
/// servers announce h3 via the `Alt-Svc` response header, so we strip those
/// advertisements to keep the client on TCP where we decrypt it, and we flag the
/// flow so the user knows the server offered h3.
///
/// This mirrors the "Disable HTTP/3" toggle common to debugging proxies.
public enum HTTP3Policy {

    /// When true, h3 `Alt-Svc` advertisements are stripped from responses.
    public static let blockHTTP3 = LockedFlag(true)

    /// Does this response advertise an HTTP/3 endpoint via `Alt-Svc`?
    /// (`canonicalForm` already splits the comma-separated entries.)
    static func advertisesHTTP3(_ headers: HTTPHeaders) -> Bool {
        headers[canonicalForm: "alt-svc"].contains { isH3Entry(String($0).trimmingCharacters(in: .whitespaces)) }
    }

    /// Returns headers with any h3 `Alt-Svc` entries removed. Non-h3 alternatives
    /// (e.g. `h2`) and a `clear` directive are preserved; if nothing remains, the
    /// header is dropped.
    static func stripHTTP3AltSvc(_ headers: HTTPHeaders) -> HTTPHeaders {
        guard headers.contains(name: "alt-svc") else { return headers }

        var rebuilt = headers
        rebuilt.remove(name: "alt-svc")

        let kept = headers[canonicalForm: "alt-svc"]
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { $0.lowercased() == "clear" || !isH3Entry($0) }
        if !kept.isEmpty {
            rebuilt.add(name: "Alt-Svc", value: kept.joined(separator: ", "))
        }
        return rebuilt
    }

    /// An Alt-Svc entry looks like `h3=":443"; ma=86400`. The protocol id is the
    /// text before `=`; h3 draft variants are `h3-29`, `h3-Q050`, etc.
    private static func isH3Entry(_ entry: String) -> Bool {
        guard let proto = entry.split(separator: "=").first?.trimmingCharacters(in: .whitespaces).lowercased()
        else { return false }
        return proto == "h3" || proto.hasPrefix("h3-")
    }
}
