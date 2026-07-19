#if os(iOS)
import Foundation
import Security
import WeaverCore

/// Verifies whether iOS *actually* trusts our CA for TLS server auth, rather
/// than assuming trust because the user tapped Install. This is the app's
/// signature feature: the two-step iOS dance (install profile → flip "Full
/// Trust" in Settings) fails silently for real users — a widely reported iOS
/// so we mint a throwaway leaf and ask `SecTrust` to evaluate it — the same
/// question a real TLS handshake asks.
enum TrustEvaluator {

    enum Status: Equatable {
        /// The profile carrying the CA isn't installed, or we can't tell yet.
        case unknown
        /// Profile installed but "Full Trust" (Settings ▸ General ▸ About ▸
        /// Certificate Trust Settings) is still off — interception won't work.
        case installedNotTrusted
        /// Fully trusted: interception will work for non-pinned apps.
        case trusted

        var isTrusted: Bool { self == .trusted }
    }

    /// Mint a leaf for a probe host, build the leaf→CA chain, and evaluate it
    /// against the system trust store with an SSL policy. Runs off the main
    /// actor (SecTrust can block).
    static func evaluate(authority: CertificateAuthority, probeHost: String = "trust-probe.weaver.local") -> Status {
        guard let leafDER = try? authority.leafDER(forHost: probeHost),
              let caDER = try? authority.certificateDER(),
              let leafSec = SecCertificateCreateWithData(nil, leafDER as CFData),
              let caSec = SecCertificateCreateWithData(nil, caDER as CFData) else {
            return .unknown
        }

        let policy = SecPolicyCreateSSL(true, probeHost as CFString)
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates([leafSec, caSec] as CFArray, policy, &trust) == errSecSuccess,
              let trust else {
            return .unknown
        }

        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return .trusted }

        // Not trusted. If the evaluated chain still reached our root, the OS
        // knows the anchor but hasn't been granted Full Trust — the flaky
        // toggle case we specifically guide the user through.
        if chainContainsOurCA(trust, ourCADER: caDER) {
            return .installedNotTrusted
        }
        return .unknown
    }

    private static func chainContainsOurCA(_ trust: SecTrust, ourCADER: Data) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return false }
        return chain.contains { (SecCertificateCopyData($0) as Data) == ourCADER }
    }
}
#endif
