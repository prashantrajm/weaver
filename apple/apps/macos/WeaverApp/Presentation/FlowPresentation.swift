import SwiftUI
import WeaverCore

/// Presentation helpers for rendering a `Flow` in the UI — status colors,
/// method/protocol labels, and formatted sizes. Kept out of the views so the
/// table and row markup stay thin and declarative.
enum FlowPresentation {
    /// Leading status dot: red on error, yellow while in-flight, green when done.
    static func statusDotColor(_ flow: Flow) -> Color {
        if flow.error != nil { return .red }
        return flow.completedAt == nil ? .yellow : .green
    }

    static func methodColor(_ method: String) -> Color {
        switch method {
        case "GET": return .blue
        case "POST": return .green
        case "PUT", "PATCH": return .orange
        case "DELETE": return .red
        default: return .primary
        }
    }

    static func statusCodeColor(_ code: Int) -> Color {
        switch code {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        default: return .red
        }
    }

    static func protoLabel(_ flow: Flow) -> String {
        if flow.tlsInterceptionFailed { return "—" }
        if flow.isWebSocket { return "WS" }
        return flow.httpVersion.contains("2") ? "H2" : "H1"
    }

    static func clientName(_ flow: Flow) -> String {
        flow.clientDescription.split(separator: "/").first.map(String.init)
            ?? (flow.clientDescription.isEmpty ? "—" : flow.clientDescription)
    }

    static func byteString(_ bytes: Int) -> String {
        if bytes == 0 { return "–" }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    /// `api.example.com` → `*.example.com` (nil for apex/short hosts and IPs).
    static func parentWildcard(of host: String) -> String? {
        let parts = host.split(separator: ".")
        guard parts.count >= 3, UInt8(parts.last ?? "") == nil else { return nil }
        return "*." + parts.dropFirst().joined(separator: ".")
    }
}

extension Flow {
    /// Display name used to group traffic by client app. Must be identical in
    /// the sidebar grouping and the list filter, or selecting a group shows
    /// nothing (best-effort: first token of the User-Agent, else "Unknown").
    var appDisplayName: String {
        clientDescription.isEmpty
            ? "Unknown"
            : (clientDescription.split(separator: "/").first.map(String.init) ?? clientDescription)
    }
}
