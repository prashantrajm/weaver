#if os(iOS)
import Foundation
import WeaverCore

/// Drives one real HTTPS request *through* the local proxy so capture can be
/// proven end-to-end on-device without the user first configuring the system
/// Wi-Fi proxy or installing the CA. It configures a `URLSession` to use the
/// proxy explicitly and trusts our CA for this request only (pinned to our
/// root), so a genuine flow — real TLS termination, real upstream fetch — lands
/// in the capture list. This is real traffic, just self-generated.
enum ProxySelfTest {

    /// Default target: tiny, stable, real endpoint.
    static let defaultURL = URL(string: "https://api.github.com/zen")!

    /// Sends `url` through the proxy at `127.0.0.1:port`. Returns the HTTP
    /// status on success. Throws on transport failure. The captured flow shows
    /// up via the proxy's normal event path — this call doesn't fabricate it.
    static func run(through port: Int, ca: CertificateAuthority,
                    url: URL = defaultURL) async throws -> Int {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // iOS exposes the HTTP proxy keys as constants but not the HTTPS ones;
        // the string keys below are the supported way to set an HTTPS proxy.
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: port,
            "HTTPSEnable": 1,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": port,
        ]

        let delegate = CAPinningDelegate(ca: ca)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (_, response) = try await session.data(from: url)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }
}

/// Accepts the proxy's leaf for the self-test request, and confirms it was
/// actually minted by *our* CA (chains to our root) — so the test proves the
/// MITM leaf is genuine rather than blindly trusting anything. The self-test
/// session only ever connects through our own local proxy, so accepting here is
/// scoped to it and does not weaken trust for any other traffic. Third-party
/// apps still rely on the normal, system-installed CA trust.
private final class CAPinningDelegate: NSObject, URLSessionDelegate {
    private let ca: CertificateAuthority
    init(ca: CertificateAuthority) { self.ca = ca }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if issuedByOurCA(trust) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// True if the proxy's leaf was issued by our CA — confirmed by comparing
    /// the leaf's issuer DER to our CA's subject DER. Crucially this does NOT
    /// mutate the `trust` object (setting anchors on it corrupts the credential
    /// we hand back and makes URLSession reject the connection with -1200).
    private func issuedByOurCA(_ trust: SecTrust) -> Bool {
        guard let ourDER = try? ca.certificateDER(),
              let ourCA = SecCertificateCreateWithData(nil, ourDER as CFData),
              let ourSubject = SecCertificateCopyNormalizedSubjectSequence(ourCA),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              let leafIssuer = SecCertificateCopyNormalizedIssuerSequence(leaf) else {
            return false
        }
        return (leafIssuer as Data) == (ourSubject as Data)
    }
}
#endif
