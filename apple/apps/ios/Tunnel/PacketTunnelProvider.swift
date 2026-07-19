import NetworkExtension
import os

/// The on-device packet tunnel — the extension process that captures traffic in
/// the background. It claims the IPv4 default route, hands every packet to a
/// userspace TCP/IP stack (`TunnelStack`) that terminates connections locally
/// and relays them to the real destination, capturing each connection to the
/// shared App Group store the app reads.
///
/// IPv6 is deliberately left unrouted so v6 traffic flows natively and keeps
/// working while iteration 1 covers IPv4. Decryption (MITM with the shared CA)
/// replaces the plain relay in the next increment; today this captures every
/// connection + its host while preserving connectivity.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: "com.weaver.ios.tunnel", category: "tunnel")
    private var stack: TunnelStack?
    private var mitm: MITMProxy?

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        log.log("startTunnel")
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.64.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]   // capture all IPv4
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        // Route DNS through the tunnel too, so name lookups are relayed.
        settings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "1.1.1.1"])

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { completionHandler(nil); return }
            if let error {
                self.log.error("setTunnelNetworkSettings failed: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            // Start the in-extension MITM proxy; :443 connections are decrypted
            // through it. If the CA hasn't been exported yet, it returns nil and
            // 443 falls back to an encrypted relay (still captured, not decrypted).
            let mitm = MITMProxy()
            let mitmPort = mitm.start()
            self.mitm = mitm

            let store = SharedCaptureStore()
            self.stack = TunnelStack(
                writePacket: { [weak self] packet in
                    self?.packetFlow.writePackets([packet], withProtocols: [AF_INET as NSNumber])
                },
                store: store,
                mitmProxyPort: mitmPort)
            self.log.log("tunnel up — capturing IPv4 (MITM \(mitmPort != nil ? "on" : "off"))")
            self.readPackets()
            completionHandler(nil)
        }
    }

    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            for packet in packets { self.stack?.input(packet) }
            self.readPackets()
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        log.log("stopTunnel: \(String(describing: reason))")
        stack?.shutdown()
        stack = nil
        mitm?.stop()
        mitm = nil
        completionHandler()
    }
}
