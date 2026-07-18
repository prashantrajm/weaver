import Foundation
import NIOSSL
import X509

/// Bridges a swift-certificates leaf (signed by our CA) into a NIOSSL server
/// TLS context we can present on the client-facing side of the MITM.
enum TLSIdentity {

    static func serverContext(
        for leaf: CertificateAuthority.MintedLeaf,
        caCertificate: Certificate
    ) throws -> NIOSSLContext {
        let leafPEM = try leaf.certificate.serializeAsPEM().pemString
        let caPEM = try caCertificate.serializeAsPEM().pemString
        let keyPEM = leaf.p256Key.pemRepresentation

        let leafCert = try NIOSSLCertificate(bytes: Array(leafPEM.utf8), format: .pem)
        let caCert = try NIOSSLCertificate(bytes: Array(caPEM.utf8), format: .pem)
        let key = try NIOSSLPrivateKey(bytes: Array(keyPEM.utf8), format: .pem)

        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(leafCert), .certificate(caCert)],
            privateKey: .privateKey(key)
        )
        // Advertise HTTP/2 and HTTP/1.1; the ALPN result selects the pipeline.
        config.applicationProtocols = ["h2", "http/1.1"]
        return try NIOSSLContext(configuration: config)
    }
}
