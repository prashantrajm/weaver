import Foundation

/// Pure transformations over a network service's `Proxies` configuration
/// dictionary (the shape SystemConfiguration hands back for
/// `kSCNetworkProtocolTypeProxies`). No system access here so it stays
/// testable on every platform; `SystemProxyConfigurator` (macOS) does the I/O.
///
/// Keys are the CFNetwork proxy keys (`kCFNetworkProxiesHTTPEnable` …) spelled
/// out so this file needs no CFNetwork import.
public enum SystemProxySettings {

    public enum Key {
        public static let httpEnable = "HTTPEnable"
        public static let httpProxy = "HTTPProxy"
        public static let httpPort = "HTTPPort"
        public static let httpsEnable = "HTTPSEnable"
        public static let httpsProxy = "HTTPSProxy"
        public static let httpsPort = "HTTPSPort"
        public static let exceptionsList = "ExceptionsList"
    }

    /// Hosts that must never be routed through the proxy: loopback (so nothing
    /// on this Mac — Weaver included — proxies to itself) and link-local /
    /// mDNS names (Bonjour, printers, AirPlay) that a proxy can't reach anyway.
    public static let requiredExceptions = ["localhost", "127.0.0.1", "::1", "*.local", "169.254/16"]

    /// Returns `current` with HTTP + HTTPS pointed at `host:port` and the
    /// required exceptions merged in. Every other key (SOCKS, PAC, FTP, the
    /// user's own exceptions, `ExcludeSimpleHostnames`) is left untouched so
    /// restoring the snapshot returns the user to exactly where they were.
    public static func applying(host: String, port: Int, to current: [String: Any]) -> [String: Any] {
        var config = current
        config[Key.httpEnable] = 1
        config[Key.httpProxy] = host
        config[Key.httpPort] = port
        config[Key.httpsEnable] = 1
        config[Key.httpsProxy] = host
        config[Key.httpsPort] = port

        var exceptions = (current[Key.exceptionsList] as? [String]) ?? []
        for entry in requiredExceptions where !exceptions.contains(entry) {
            exceptions.append(entry)
        }
        config[Key.exceptionsList] = exceptions
        return config
    }

    /// True when this configuration currently routes HTTP or HTTPS through
    /// `host:port` — i.e. it's ours. Used at launch to tell "we crashed and
    /// left the system proxy pointing at a dead port" from "the user changed it".
    public static func pointsAt(host: String, port: Int, in config: [String: Any]) -> Bool {
        func matches(_ enableKey: String, _ hostKey: String, _ portKey: String) -> Bool {
            guard (config[enableKey] as? NSNumber)?.intValue == 1 else { return false }
            return (config[hostKey] as? String) == host && (config[portKey] as? NSNumber)?.intValue == port
        }
        return matches(Key.httpEnable, Key.httpProxy, Key.httpPort)
            || matches(Key.httpsEnable, Key.httpsProxy, Key.httpsPort)
    }
}
