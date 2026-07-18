import SwiftUI
import WeaverCore

/// Content-aware body viewer: pretty-prints JSON/XML, falls back to UTF-8 text,
/// and shows a hex dump for binary payloads (M1.3). Rendering is shared with the
/// copy button via `BodyRenderer`.
struct BodyView: View {
    let data: Data?
    let contentType: String?
    let raw: Bool

    var body: some View {
        guard let data, !data.isEmpty else {
            return AnyView(EmptyPane(text: "No body"))
        }
        let rendered = BodyRenderer.text(data, contentType: contentType, raw: raw)
        return AnyView(
            ScrollView([.horizontal, .vertical]) {
                Text(rendered)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        )
    }
}

/// Renders an image body scaled to fit, with its pixel size and byte count.
struct ImagePreviewView: View {
    let data: Data?

    var body: some View {
        if let data, let image = BodyRenderer.image(from: data) {
            VStack(spacing: 6) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(10)
                }
                Text("\(Int(image.size.width))×\(Int(image.size.height)) · \(byteString(data.count))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }
        } else {
            EmptyPane(text: "Not a previewable image")
        }
    }

    private func byteString(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}
