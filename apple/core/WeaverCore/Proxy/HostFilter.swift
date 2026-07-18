import Foundation

/// Thread-safe set of host patterns to **bypass** (tunnel without decryption).
///
/// Bypassing a host leaves the app's own TLS untouched, so a pinned app keeps
/// working through the proxy instead of failing our interception — and it keeps
/// noisy/irrelevant hosts out of the capture. Read on NIO threads at CONNECT
/// time, mutated from the UI.
///
/// Patterns match either an exact host (`api.example.com`) or a wildcard suffix
/// (`*.example.com`, which also matches the apex `example.com`).
public final class HostFilter: @unchecked Sendable {

    private let lock = NSLock()
    private var patterns: [String] = []

    public init(bypass: [String] = []) {
        self.patterns = normalize(bypass)
    }

    public var bypassPatterns: [String] {
        lock.lock(); defer { lock.unlock() }
        return patterns
    }

    public func shouldBypass(_ host: String) -> Bool {
        let h = host.lowercased()
        lock.lock(); defer { lock.unlock() }
        return patterns.contains { Self.matches(pattern: $0, host: h) }
    }

    public func addBypass(_ pattern: String) {
        let p = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        guard !p.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if !patterns.contains(p) { patterns.append(p) }
    }

    public func removeBypass(_ pattern: String) {
        let p = pattern.lowercased()
        lock.lock(); defer { lock.unlock() }
        patterns.removeAll { $0 == p }
    }

    private func normalize(_ list: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in list {
            let p = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if !p.isEmpty, seen.insert(p).inserted { out.append(p) }
        }
        return out
    }

    static func matches(pattern: String, host: String) -> Bool {
        if pattern.hasPrefix("*.") {
            let base = pattern.dropFirst(2)
            return host == base || host.hasSuffix("." + base)
        }
        return host == pattern
    }
}
