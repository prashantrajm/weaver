import Foundation
import Crypto
import X509
import SwiftASN1

/// Per-install root Certificate Authority plus on-the-fly leaf minting.
///
/// This is the security-critical, reusable core (M1.2). The CA private key is
/// generated locally and must never be shipped or exported off-device. Leaf
/// certificates are minted per host at capture time and signed by this CA, so
/// the client's TLS handshake succeeds *only* once the device trusts the CA.
public final class CertificateAuthority: @unchecked Sendable {

    public let certificate: Certificate
    private let privateKey: Certificate.PrivateKey
    private let signingKey: P256.Signing.PrivateKey

    /// Cache of minted leaf certs keyed by host so repeat connections to the
    /// same host reuse one identity instead of re-signing every handshake.
    private let leafCacheLock = NSLock()
    private var leafCache: [String: MintedLeaf] = [:]

    public struct MintedLeaf: Sendable {
        public let certificate: Certificate
        public let privateKey: Certificate.PrivateKey
        public let p256Key: P256.Signing.PrivateKey
    }

    /// Create a CA from an existing key + certificate (loaded from storage).
    public init(certificate: Certificate, signingKey: P256.Signing.PrivateKey) {
        self.certificate = certificate
        self.signingKey = signingKey
        self.privateKey = Certificate.PrivateKey(signingKey)
    }

    /// Generate a fresh per-install root CA valid for 10 years.
    public static func generate(commonName: String = "Weaver Root CA") throws -> CertificateAuthority {
        let key = P256.Signing.PrivateKey()
        let certKey = Certificate.PrivateKey(key)

        let subject = try DistinguishedName {
            CommonName(commonName)
            OrganizationName("Weaver")
        }

        let now = Date()
        let notBefore = now.addingTimeInterval(-60 * 60 * 24)          // yesterday, for clock skew
        let notAfter = now.addingTimeInterval(60 * 60 * 24 * 365 * 10) // ~10 years

        let extensions = try Certificate.Extensions {
            Critical(
                BasicConstraints.isCertificateAuthority(maxPathLength: 1)
            )
            Critical(
                KeyUsage(keyCertSign: true, cRLSign: true)
            )
            SubjectKeyIdentifier(hash: certKey.publicKey)
        }

        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: certKey.publicKey,
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            issuer: subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: certKey
        )

        return CertificateAuthority(certificate: cert, signingKey: key)
    }

    /// Mint (or return cached) a leaf certificate for `host`, signed by this CA.
    public func leaf(forHost host: String) throws -> MintedLeaf {
        leafCacheLock.lock()
        if let cached = leafCache[host] {
            leafCacheLock.unlock()
            return cached
        }
        leafCacheLock.unlock()

        let leafKey = P256.Signing.PrivateKey()
        let leafCertKey = Certificate.PrivateKey(leafKey)

        let subject = try DistinguishedName {
            CommonName(host)
        }

        let now = Date()
        let notBefore = now.addingTimeInterval(-60 * 60 * 24)
        let notAfter = now.addingTimeInterval(60 * 60 * 24 * 397) // ~13 months (CA/B limit)

        let san = try subjectAlternativeName(for: host)

        let extensions = try Certificate.Extensions {
            Critical(
                BasicConstraints.notCertificateAuthority
            )
            KeyUsage(digitalSignature: true, keyEncipherment: true)
            try ExtendedKeyUsage([.serverAuth])
            SubjectKeyIdentifier(hash: leafCertKey.publicKey)
            AuthorityKeyIdentifier(keyIdentifier: try certificate.extensions.subjectKeyIdentifier?.keyIdentifier)
            san
        }

        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: leafCertKey.publicKey,
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            issuer: certificate.subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: privateKey
        )

        let minted = MintedLeaf(certificate: cert, privateKey: leafCertKey, p256Key: leafKey)
        leafCacheLock.lock()
        leafCache[host] = minted
        leafCacheLock.unlock()
        return minted
    }

    private func subjectAlternativeName(for host: String) throws -> SubjectAlternativeNames {
        // If the host is an IPv4/IPv6 literal, emit an iPAddress SAN (raw octets);
        // otherwise a DNS SAN.
        if let octets = ipv4Octets(host) {
            return SubjectAlternativeNames([.ipAddress(ASN1OctetString(contentBytes: octets[...]))])
        }
        return SubjectAlternativeNames([.dnsName(host)])
    }

    private func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part) else { return nil }
            octets.append(value)
        }
        return octets
    }

    // MARK: - Serialization

    /// PEM of the CA certificate — this is what gets installed/trusted on devices.
    public func certificatePEM() throws -> String {
        try certificate.serializeAsPEM().pemString
    }

    /// PEM of the CA private key. Kept only for on-device persistence; never export.
    public func privateKeyPEM() throws -> String {
        signingKey.pemRepresentation
    }

    public static func load(certificatePEM: String, privateKeyPEM: String) throws -> CertificateAuthority {
        let key = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
        let cert = try Certificate(pemEncoded: certificatePEM)
        return CertificateAuthority(certificate: cert, signingKey: key)
    }
}
