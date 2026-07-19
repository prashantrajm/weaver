#if os(iOS)
import SwiftUI
import WeaverCore
import InspectorKit

/// Content-type filter chips in a horizontally scrollable row
/// (All · HTTP · HTTPS · WebSocket · JSON · …). One tap narrows the list; a
/// second tap on the active chip clears it. The chips are custom app chrome, so
/// they get a real Liquid Glass treatment grouped in one `GlassEffectContainer`
/// (a shared container is a correctness rule — separate ones can't sample each
/// other's glass and refract inconsistently).
struct FilterChipBar: View {
    @Binding var selection: FlowKind?

    private let kinds: [FlowKind] = [
        .http, .https, .websocket, .json, .form, .xml, .js, .css, .document, .media,
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    chip(title: "All", isSelected: selection == nil) { selection = nil }
                    ForEach(kinds, id: \.self) { kind in
                        chip(title: kind.rawValue, isSelected: selection == kind) {
                            selection = (selection == kind) ? nil : kind
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .scrollClipDisabled()
    }

    private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
        }
        .buttonStyle(.glass)
        .tint(isSelected ? .accentColor : nil)
        .buttonBorderShape(.capsule)
    }
}
#endif
