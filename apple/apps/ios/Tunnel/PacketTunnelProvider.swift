import NetworkExtension
import os

/// The on-device packet tunnel (iOS-P1 real capture). This is the extension
/// process that keeps running in the background while capturing.
///
/// Milestone 0 (this file): establish the tunnel, prove the Network Extension
/// entitlement provisions and runs on-device, and start the packet read loop.
/// It claims only a documentation subnet (RFC 5737 192.0.2.0/24) so turning the
/// VPN on does NOT disrupt real connectivity while we validate the plumbing.
///
/// Next milestones layer the userspace TCP/IP stack on top of the read loop:
/// parse IPv4/TCP, reassemble streams, terminate TLS with a leaf minted by the
/// shared CA, forward to the origin, and write responses back to `packetFlow`.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: "com.weaver.ios.tunnel", category: "tunnel")
    private var packetCount = 0

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        log.log("startTunnel")
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        let ipv4 = NEIPv4Settings(addresses: ["192.0.2.2"], subnetMasks: ["255.255.255.0"])
        // M0: route only the documentation range so real traffic is untouched.
        // The full stack switches this to NEIPv4Route.default() to capture all.
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "192.0.2.0",
                                           subnetMask: "255.255.255.0")]
        settings.ipv4Settings = ipv4
        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { completionHandler(nil); return }
            if let error {
                self.log.error("setTunnelNetworkSettings failed: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            self.log.log("tunnel up — reading packets")
            self.readPackets()
            completionHandler(nil)
        }
    }

    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            if !packets.isEmpty {
                self.packetCount += packets.count
                self.log.log("read \(packets.count) packets (total \(self.packetCount))")
            }
            // M0: drop captured packets. TCP/IP reassembly + MITM comes next.
            self.readPackets()
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        log.log("stopTunnel: \(String(describing: reason))")
        completionHandler()
    }
}
