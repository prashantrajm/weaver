import Foundation
import SwiftUI
import WeaverCore

/// View model for the main inspector screen. Owns the screen's UI state
/// (search text, type filter, sidebar selection, row selection) and all
/// derivation of the visible flow list and sidebar groups from the session's
/// captured flows. Views bind to this and stay presentation-only; the captured
/// data itself lives in the session store (macOS: `CaptureController`,
/// iOS: `IOSCaptureStore`). Shared by both Apple apps.
@MainActor
public final class InspectorViewModel: ObservableObject {
    @Published public var searchText = ""
    @Published public var typeFilter: FlowKind? = nil
    @Published public var sidebarSelection: SidebarSelection = .allTraffic
    @Published public var selectedFlowID: Flow.ID?

    public init() {}

    /// Flows matching the current sidebar selection, type filter, and search.
    public func filtered(_ flows: [Flow]) -> [Flow] {
        flows.filter { flow in
            if let typeFilter, flow.kind != typeFilter { return false }
            switch sidebarSelection {
            case .allTraffic: break
            case .app(let name): if flow.appDisplayName != name { return false }
            case .domain(let host): if flow.host != host { return false }
            }
            if !searchText.isEmpty {
                let haystack = "\(flow.url.absoluteString) \(flow.method) \(flow.host)".lowercased()
                if !haystack.contains(searchText.lowercased()) { return false }
            }
            return true
        }
    }

    /// The currently selected flow, resolved against the live flow list.
    public func selectedFlow(in flows: [Flow]) -> Flow? {
        flows.first { $0.id == selectedFlowID }
    }

    /// Traffic grouped by client app, most-active first.
    public func appGroups(_ flows: [Flow]) -> [FlowGroup] {
        group(flows, by: { $0.appDisplayName })
    }

    /// Traffic grouped by host, most-active first.
    public func domainGroups(_ flows: [Flow]) -> [FlowGroup] {
        group(flows, by: { $0.host })
    }

    private func group(_ flows: [Flow], by key: (Flow) -> String) -> [FlowGroup] {
        var counts: [String: Int] = [:]
        for flow in flows { counts[key(flow), default: 0] += 1 }
        return counts
            .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map { FlowGroup(name: $0.key, count: $0.value) }
    }
}

/// A named group of flows (by app or domain) with its request count.
public struct FlowGroup: Identifiable, Hashable {
    public let name: String
    public let count: Int
    public var id: String { name }
    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

/// What the sidebar is filtering the traffic list by.
public enum SidebarSelection: Hashable {
    case allTraffic
    case app(String)
    case domain(String)
}
