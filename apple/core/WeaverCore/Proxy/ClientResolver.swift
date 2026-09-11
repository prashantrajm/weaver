import Foundation
import NIO

/// Maps an accepted connection back to the process that opened it. Only
/// meaningful for connections from the local machine; the proxy asks the
/// resolver for loopback clients only.
public protocol ClientResolver: AnyObject, Sendable {
    /// - Parameters:
    ///   - clientPort: the connection's source (client-side) port.
    ///   - proxyPort: the port the client connected to (our listener), used to
    ///     disambiguate the socket.
    ///   - completion: called once, on an arbitrary thread, with the owner or nil.
    func resolve(clientPort: Int, proxyPort: Int, completion: @escaping @Sendable (ClientProcess?) -> Void)
}

/// Per-connection event handler that stamps every flow started on that
/// connection with its `ClientProcess`, then forwards to the real handler.
///
/// Resolution is asynchronous and a fast plain-HTTP request can start a flow
/// before it lands, so flows started early are held and patched when the
/// answer arrives (with a `flowDidUpdate` so the UI regroups). Handlers only
/// hold this weakly; `ProxyServer` keeps it alive for the connection's lifetime.
final class ConnectionEventTagger: ProxyEventHandler, @unchecked Sendable {
    private weak var upstream: ProxyEventHandler?
    private let lock = NSLock()
    private var process: ClientProcess?
    private var resolved = false
    private var pending: [Flow] = []

    init(upstream: ProxyEventHandler?) {
        self.upstream = upstream
    }

    /// Deliver the resolution (nil when unknown). Idempotent: first answer wins.
    func resolved(_ process: ClientProcess?) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        resolved = true
        self.process = process
        let waiting = pending
        pending.removeAll()
        lock.unlock()

        guard let process else { return }
        for flow in waiting {
            flow.clientProcess = process
            upstream?.flowDidUpdate(flow)
        }
    }

    func flowDidStart(_ flow: Flow) {
        lock.lock()
        if resolved {
            flow.clientProcess = process
        } else {
            pending.append(flow)
        }
        lock.unlock()
        upstream?.flowDidStart(flow)
    }

    func flowDidComplete(_ flow: Flow) { upstream?.flowDidComplete(flow) }
    func flowDidUpdate(_ flow: Flow) { upstream?.flowDidUpdate(flow) }
    func proxyDidLog(_ message: String) { upstream?.proxyDidLog(message) }
}
