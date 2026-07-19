#if os(iOS)
import Foundation
import WeaverCore

/// Real on-device capture (iOS-P1, phase 1): runs the shared `ProxyServer` —
/// the same tested MITM proxy the macOS app uses — bound to loopback inside the
/// app. Any app on the device whose Wi-Fi HTTP proxy is pointed at
/// `127.0.0.1:<port>` (and that trusts our CA) is captured and decrypted here,
/// reusing 100% of WeaverCore's TLS termination and flow model.
///
/// Ceiling, stated honestly: this captures proxy-aware traffic (URLSession /
/// CFNetwork, i.e. most apps) only while Weaver is in the foreground — iOS
/// suspends the app's sockets in the background. Automatic, backgrounded,
/// zero-config capture is the NEPacketTunnelProvider follow-up;
/// this backend is what makes capture *real* today.
@MainActor
final class LocalProxyBackend: CaptureBackend {
    let host: String
    let port: Int

    private let authority: CertificateAuthority
    private let filter: HostFilter
    private var server: ProxyServer?

    var listenAddress: String { "\(host):\(port)" }

    init(authority: CertificateAuthority, filter: HostFilter,
         host: String = "127.0.0.1", port: Int = 9090) {
        self.authority = authority
        self.filter = filter
        self.host = host
        self.port = port
    }

    func start(events: ProxyEventHandler) throws {
        guard server == nil else { return }
        let server = ProxyServer(host: host, port: port, ca: authority,
                                 events: events, filter: filter)
        try server.start()
        self.server = server
    }

    func stop() {
        server?.shutdown()
        server = nil
    }
}
#endif
