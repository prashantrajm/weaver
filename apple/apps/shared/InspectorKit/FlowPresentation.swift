import SwiftUI
import WeaverCore

/// Presentation helpers for rendering a `Flow` in the UI — status colors,
/// method/protocol labels, and formatted sizes. Kept out of the views so the
/// table and row markup stay thin and declarative. Shared by both Apple apps.
public enum FlowPresentation {
    /// Leading status dot: red on error, yellow while in-flight, green when done.
    public static func statusDotColor(_ flow: Flow) -> Color {
        if flow.error != nil { return .red }
        return flow.completedAt == nil ? .yellow : .green
    }

    public static func methodColor(_ method: String) -> Color {
        switch method {
        case "GET": return .blue
        case "POST": return .green
        case "PUT", "PATCH": return .orange
        case "DELETE": return .red
        default: return .primary
        }
    }

    public static func statusCodeColor(_ code: Int) -> Color {
        switch code {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        default: return .red
        }
    }

    public static func protoLabel(_ flow: Flow) -> String {
        if flow.tlsInterceptionFailed { return "—" }
        if flow.isWebSocket { return "WS" }
        return flow.httpVersion.contains("2") ? "H2" : "H1"
    }

    public static func clientName(_ flow: Flow) -> String {
        flow.clientDescription.split(separator: "/").first.map(String.init)
            ?? (flow.clientDescription.isEmpty ? "—" : flow.clientDescription)
    }

    public static func byteString(_ bytes: Int) -> String {
        if bytes == 0 { return "–" }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    /// Wall-clock time a request was sent, locale-aware with seconds
    /// (e.g. "4:30:45 PM" or "16:30:45"). Used on the request rows.
    public static func timeOfDay(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    /// Full timestamp with the date, for the detail card (e.g. "Jul 19, 4:30:45 PM").
    public static func timestamp(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().hour().minute().second())
    }

    /// Latency, scaled to the magnitude: sub-second in ms, otherwise seconds.
    /// `nil` while the response is still in flight.
    public static func durationString(_ ms: Double?) -> String? {
        guard let ms else { return nil }
        if ms < 1000 { return String(format: "%.0f ms", ms) }
        return String(format: "%.2f s", ms / 1000)
    }

    /// Duration color as a light speed cue — Apple-style semantic tinting:
    /// green for snappy, orange for slow, red for very slow.
    public static func durationColor(_ ms: Double) -> Color {
        switch ms {
        case ..<300: return .green
        case ..<1000: return .primary
        case ..<3000: return .orange
        default: return .red
        }
    }

    /// `api.example.com` → `*.example.com` (nil for apex/short hosts and IPs).
    public static func parentWildcard(of host: String) -> String? {
        let parts = host.split(separator: ".")
        guard parts.count >= 3, UInt8(parts.last ?? "") == nil else { return nil }
        return "*." + parts.dropFirst().joined(separator: ".")
    }
}

extension Flow {
    /// Display name used to group traffic by client app. Must be identical in
    /// the sidebar grouping and the list filter, or selecting a group shows
    /// nothing (best-effort: first token of the User-Agent, else "Unknown").
    public var appDisplayName: String {
        clientDescription.isEmpty
            ? "Unknown"
            : (clientDescription.split(separator: "/").first.map(String.init) ?? clientDescription)
    }
}
