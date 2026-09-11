#if os(macOS)
import Foundation
import Darwin

/// Finds which local process owns the client end of a proxied connection by
/// scanning open TCP sockets with libproc (public API, no root, ~2–7 ms for a
/// full scan). Runs on its own serial queue so the event loop never waits.
///
/// Matching uses both ends of the socket: local port == the client's source
/// port *and* foreign port == our listener. Processes owned by other users
/// are invisible without root and resolve to nil (the UI then falls back to
/// User-Agent grouping).
public final class LocalProcessResolver: ClientResolver, @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.weaver.process-resolver", qos: .userInitiated)
    /// Most connections in a burst come from the same app: check it first.
    private var lastMatchedPID: pid_t = 0
    /// Bundle lookups are the slow part; pid metadata is stable for a pid's life.
    private var metadataCache: [pid_t: ClientProcess] = [:]

    public init() {}

    public func resolve(clientPort: Int, proxyPort: Int, completion: @escaping @Sendable (ClientProcess?) -> Void) {
        queue.async { [self] in
            completion(resolveSync(clientPort: clientPort, proxyPort: proxyPort))
        }
    }

    /// Synchronous variant for tests and callers already off the main thread.
    public func resolveSync(clientPort: Int, proxyPort: Int) -> ClientProcess? {
        guard let pid = Self.findOwner(localPort: UInt16(clientPort), foreignPort: UInt16(proxyPort),
                                       tryFirst: lastMatchedPID) else { return nil }
        lastMatchedPID = pid
        return describe(pid)
    }

    // MARK: - Socket scan

    private static func findOwner(localPort: UInt16, foreignPort: UInt16, tryFirst: pid_t) -> pid_t? {
        if tryFirst > 0, owns(pid: tryFirst, localPort: localPort, foreignPort: foreignPort) {
            return tryFirst
        }
        for pid in allPIDs() where pid != tryFirst && pid > 0 {
            if owns(pid: pid, localPort: localPort, foreignPort: foreignPort) { return pid }
        }
        return nil
    }

    private static func allPIDs() -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size)
        let filled = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, bytes) }
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled) / MemoryLayout<pid_t>.size))
    }

    private static func owns(pid: pid_t, localPort: UInt16, foreignPort: UInt16) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }   // gone, or not ours to inspect
        let count = Int(size) / MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, size) }
        guard got > 0 else { return false }

        var info = socket_fdinfo()
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size)
        where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            let n = withUnsafeMutablePointer(to: &info) {
                proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, $0, Int32(MemoryLayout<socket_fdinfo>.size))
            }
            guard n == Int32(MemoryLayout<socket_fdinfo>.size),
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let ini = info.psi.soi_proto.pri_tcp.tcpsi_ini
            // Ports are stored in network byte order.
            let lport = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
            let fport = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport))
            if lport == localPort && fport == foreignPort { return true }
        }
        return false
    }

    // MARK: - Process metadata

    private func describe(_ pid: pid_t) -> ClientProcess? {
        if let cached = metadataCache[pid] { return cached }
        var target = pid
        var path = Self.executablePath(of: pid)
        // System-launched helpers (Safari's `com.apple.WebKit.Networking.xpc`,
        // app extensions) attribute to the app responsible for them. Only for
        // those: the "responsible" process for a CLI tool is its terminal, and
        // `curl` should read as curl, not Ghostty.
        if let p = path, Self.isSystemHelper(p) {
            let responsible = Self.responsiblePID(for: pid)
            if responsible > 0, responsible != pid {
                target = responsible
                path = Self.executablePath(of: responsible)
            }
        }
        if target != pid, let cached = metadataCache[target] {
            metadataCache[pid] = cached
            return cached
        }
        var name = Self.processName(of: target)
        var bundleID: String?
        var bundlePath: String?
        if let path, let appPath = Self.enclosingAppBundle(of: path), let bundle = Bundle(path: appPath) {
            bundlePath = appPath
            bundleID = bundle.bundleIdentifier
            name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        guard let name, !name.isEmpty else { return nil }
        let process = ClientProcess(pid: target, name: name, bundleIdentifier: bundleID,
                                    bundlePath: bundlePath, executablePath: path)
        metadataCache[pid] = process
        metadataCache[target] = process
        return process
    }

    /// A binary that lives in an XPC service, app extension, or framework and
    /// not inside any `.app` — launched on behalf of some app rather than by
    /// the user.
    static func isSystemHelper(_ executablePath: String) -> Bool {
        guard enclosingAppBundle(of: executablePath) == nil else { return false }
        return executablePath.contains(".xpc/") || executablePath.contains(".appex/")
            || executablePath.contains(".framework/")
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return n > 0 ? String(cString: buffer) : nil
    }

    private static func processName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let n = proc_name(pid, &buffer, UInt32(buffer.count))
        return n > 0 ? String(cString: buffer) : nil
    }

    /// `/Applications/Safari.app/Contents/MacOS/Safari` → `/Applications/Safari.app`.
    /// Picks the outermost `.app` so a nested helper app (`Foo.app/Contents/
    /// Frameworks/Helper.app`) still attributes to `Foo`.
    static func enclosingAppBundle(of executablePath: String) -> String? {
        let parts = executablePath.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return parts[...index].joined(separator: "/")
    }

    /// `responsibility_get_pid_responsible_for_pid` (libsystem, not in the SDK
    /// headers but exported and stable; Activity Monitor relies on the same idea).
    private static let responsibleLookup: (@convention(c) (pid_t) -> pid_t)? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    private static func responsiblePID(for pid: pid_t) -> pid_t {
        responsibleLookup?(pid) ?? pid
    }
}
#endif
