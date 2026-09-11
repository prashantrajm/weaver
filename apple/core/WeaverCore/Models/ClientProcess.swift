import Foundation

/// The local process that opened a proxied connection, when the client is the
/// machine Weaver runs on. Resolved from the connection's source port (see
/// `LocalProcessResolver`), so it is exact rather than a User-Agent guess.
///
/// `pid`/`name` describe the *responsible* app where one exists: Safari's
/// `com.apple.WebKit.Networking` helper and Chrome's network helper both
/// attribute to their parent app, which is what a user expects to see.
public struct ClientProcess: Hashable, Sendable {
    public let pid: Int32
    /// Human-readable name: the app's display name, else the executable name.
    public let name: String
    public let bundleIdentifier: String?
    /// Path to the `.app` bundle, if the process belongs to one (for icons).
    public let bundlePath: String?
    public let executablePath: String?

    public init(pid: Int32, name: String, bundleIdentifier: String? = nil,
                bundlePath: String? = nil, executablePath: String? = nil) {
        self.pid = pid
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.executablePath = executablePath
    }
}
