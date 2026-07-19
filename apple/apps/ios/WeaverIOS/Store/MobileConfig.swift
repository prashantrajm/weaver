#if os(iOS)
import Foundation
import WeaverCore

/// Builds a `.mobileconfig` configuration profile that carries the per-install
/// CA certificate. This is how a CA gets onto iOS — there's no keychain API to
/// install a trusted root; the user opens this profile in Settings, installs
/// it, then flips "Full Trust". We generate it on-device from the live CA so
/// the profile always matches the key this install actually signs with.
enum MobileConfig {

    /// Serialized (binary or XML) property-list profile data ready to write to
    /// a `.mobileconfig` file and hand to the share sheet / Settings.
    static func profileData(for authority: CertificateAuthority) throws -> Data {
        let caDER = try authority.certificateDER()

        // Stable per-install identifiers so re-installing replaces (not
        // duplicates) the profile. Derived deterministically from the CA DER.
        let profileUUID = deterministicUUID(from: caDER, salt: "profile")
        let payloadUUID = deterministicUUID(from: caDER, salt: "payload")

        let certPayload: [String: Any] = [
            "PayloadType": "com.apple.security.root",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.weaver.ca.cert",
            "PayloadUUID": payloadUUID,
            "PayloadDisplayName": "Weaver Root CA",
            "PayloadContent": caDER,
        ]

        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.weaver.ca",
            "PayloadUUID": profileUUID,
            "PayloadDisplayName": "Weaver CA",
            "PayloadDescription": "Installs the Weaver debugging certificate so this device's HTTPS can be inspected on-device. Remove it any time in Settings ▸ General ▸ VPN & Device Management.",
            "PayloadOrganization": "Weaver",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [certPayload],
        ]

        return try PropertyListSerialization.data(
            fromPropertyList: profile, format: .xml, options: 0)
    }

    private static func deterministicUUID(from data: Data, salt: String) -> String {
        var hasher = Hasher()
        hasher.combine(data)
        hasher.combine(salt)
        let h = UInt64(bitPattern: Int64(hasher.finalize()))
        // Format as a UUID-shaped string; stability matters, not RFC 4122 bits.
        let hi = String(format: "%08X", UInt32(truncatingIfNeeded: h >> 32))
        let lo = String(format: "%08X", UInt32(truncatingIfNeeded: h))
        return "\(hi)-\(lo.prefix(4))-4000-8000-\(hi)\(lo.prefix(4))"
    }
}
#endif
