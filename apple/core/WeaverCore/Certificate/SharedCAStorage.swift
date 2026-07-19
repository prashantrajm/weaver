import Foundation

/// File-based CA sharing between the iOS app and its packet-tunnel extension.
///
/// The two run in separate processes, so the extension must load the *same* CA
/// the user already installed and trusted (minted leaves are only accepted if
/// they chain to that exact root). The app writes the CA's cert + key PEM into
/// the shared App Group container; the extension reads them. On-device only —
/// the key never leaves the device, and the container is sandboxed to these two
/// signed targets.
public enum SharedCAStorage {
    private static let certName = "shared-ca.pem"
    private static let keyName = "shared-ca-key.pem"

    /// Write the CA (public cert + private key) into `directory` (the App Group
    /// container). Overwrites any previous copy so trust stays in sync with what
    /// the app currently uses.
    public static func write(_ authority: CertificateAuthority, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let certURL = directory.appendingPathComponent(certName)
        let keyURL = directory.appendingPathComponent(keyName)
        try authority.certificatePEM().write(to: certURL, atomically: true, encoding: .utf8)
        let keyPEM = try authority.privateKeyPEM()
        try keyPEM.write(to: keyURL, atomically: true, encoding: .utf8)
        // Key file: protect at rest, and never include in backups.
        try? (keyURL as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
    }

    /// Load the shared CA from `directory`, or nil if it hasn't been written yet.
    public static func load(from directory: URL) throws -> CertificateAuthority? {
        let certURL = directory.appendingPathComponent(certName)
        let keyURL = directory.appendingPathComponent(keyName)
        guard FileManager.default.fileExists(atPath: certURL.path),
              FileManager.default.fileExists(atPath: keyURL.path) else { return nil }
        let certPEM = try String(contentsOf: certURL, encoding: .utf8)
        let keyPEM = try String(contentsOf: keyURL, encoding: .utf8)
        return try CertificateAuthority.load(certificatePEM: certPEM, privateKeyPEM: keyPEM)
    }
}
