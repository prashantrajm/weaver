import Foundation
#if canImport(Security)
import Security
#endif

/// Loads/persists the per-install CA and manages its trust state on macOS
/// (M1.2). The private key lives in the login keychain and is never exported;
/// the public certificate is written to Application Support so it can be
/// installed and served to devices for setup (M1.4).
public final class CAManager: @unchecked Sendable {

    public enum TrustState: Equatable, Sendable {
        case notInstalled
        case installedNotTrusted
        case trusted
    }

    private let keychainAccount = "com.weaver.ca.privatekey"
    private let keychainService = "Weaver CA"

    public private(set) var authority: CertificateAuthority

    private let storageDirectory: URL

    public var certificatePEMURL: URL { storageDirectory.appendingPathComponent("weaver-ca.pem") }

    public init() throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Weaver", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageDirectory = dir

        if let loaded = try Self.loadFromDisk(directory: dir, keychainService: keychainService, keychainAccount: keychainAccount) {
            self.authority = loaded
        } else {
            let ca = try CertificateAuthority.generate()
            self.authority = ca
            try Self.persist(ca, directory: dir, keychainService: keychainService, keychainAccount: keychainAccount)
        }
        try? authority.certificatePEM().write(to: certificatePEMURL, atomically: true, encoding: .utf8)
    }

    /// Discard the current CA and generate a fresh one (M1.2 regenerate).
    public func regenerate() throws {
        deleteKeyFromKeychain()
        let ca = try CertificateAuthority.generate()
        self.authority = ca
        try Self.persist(ca, directory: storageDirectory, keychainService: keychainService, keychainAccount: keychainAccount)
        try authority.certificatePEM().write(to: certificatePEMURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Persistence

    private static func loadFromDisk(directory: URL, keychainService: String, keychainAccount: String) throws -> CertificateAuthority? {
        let certURL = directory.appendingPathComponent("weaver-ca.pem")
        guard FileManager.default.fileExists(atPath: certURL.path),
              let certPEM = try? String(contentsOf: certURL, encoding: .utf8),
              let keyPEM = readKeyFromKeychain(service: keychainService, account: keychainAccount) else {
            return nil
        }
        return try CertificateAuthority.load(certificatePEM: certPEM, privateKeyPEM: keyPEM)
    }

    private static func persist(_ ca: CertificateAuthority, directory: URL, keychainService: String, keychainAccount: String) throws {
        let certPEM = try ca.certificatePEM()
        try certPEM.write(to: directory.appendingPathComponent("weaver-ca.pem"), atomically: true, encoding: .utf8)
        let keyPEM = try ca.privateKeyPEM()
        writeKeyToKeychain(keyPEM, service: keychainService, account: keychainAccount)
    }

    // MARK: - Keychain (login) — CA private key

    private static func writeKeyToKeychain(_ pem: String, service: String, account: String) {
        #if canImport(Security)
        let data = Data(pem.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
        #endif
    }

    private static func readKeyFromKeychain(service: String, account: String) -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    private func deleteKeyFromKeychain() {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        #endif
    }

    // MARK: - System trust (macOS)

    #if os(macOS)
    /// Install + trust the CA in the System keychain. Prompts for admin auth.
    /// Returns true on success.
    @discardableResult
    public func installAndTrust() throws -> Bool {
        let pemPath = certificatePEMURL.path
        // `security add-trusted-cert` into the System keychain requires admin.
        let script = """
        do shell script "security add-trusted-cert -d -r trustRoot -p ssl -k /Library/Keychains/System.keychain \\"\(pemPath)\\"" with administrator privileges
        """
        return runOSAScript(script)
    }

    /// Remove the CA from the System keychain (M1.2 uninstall).
    @discardableResult
    public func uninstall() -> Bool {
        let script = """
        do shell script "security delete-certificate -c \\"Weaver Root CA\\" /Library/Keychains/System.keychain" with administrator privileges
        """
        return runOSAScript(script)
    }

    /// Best-effort trust detection: is our CA present + trusted in a keychain?
    public func trustState() -> TrustState {
        let found = shell("/usr/bin/security", ["find-certificate", "-c", "Weaver Root CA", "-a"])
        guard found.status == 0, found.output.contains("Weaver Root CA") else {
            return .notInstalled
        }
        // If the cert verifies for SSL policy, treat as trusted.
        let verify = shell("/usr/bin/security", ["verify-cert", "-c", certificatePEMURL.path, "-p", "ssl"])
        return verify.status == 0 ? .trusted : .installedNotTrusted
    }

    private func runOSAScript(_ script: String) -> Bool {
        let result = shell("/usr/bin/osascript", ["-e", script])
        return result.status == 0
    }

    private func shell(_ launchPath: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, String(describing: error))
        }
    }
    #endif
}
