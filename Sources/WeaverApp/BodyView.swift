import SwiftUI
import WeaverCore

/// Content-aware body viewer: pretty-prints JSON, falls back to UTF-8 text, and
/// shows a hex dump for binary payloads (M1.3).
struct BodyView: View {
    let data: Data?
    let contentType: String?
    let raw: Bool

    var body: some View {
        guard let data, !data.isEmpty else {
            return AnyView(EmptyPane(text: "No body"))
        }
        let rendered = render(data)
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

    private func render(_ data: Data) -> String {
        let ct = (contentType ?? "").lowercased()
        if !raw && ct.contains("json"), let pretty = prettyJSON(data) {
            return pretty
        }
        if ct.contains("json") || ct.contains("xml") || ct.contains("text")
            || ct.contains("javascript") || ct.contains("html") || ct.contains("form")
            || ct.isEmpty {
            if let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        // Binary → hex dump.
        return hexDump(data)
    }

    private func prettyJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }

    private func hexDump(_ data: Data) -> String {
        var lines: [String] = []
        let bytes = [UInt8](data.prefix(4096))
        var offset = 0
        while offset < bytes.count {
            let slice = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = slice.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = slice.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            lines.append(String(format: "%08x  %-47s  %@", offset, (hex as NSString).utf8String!, ascii))
            offset += 16
        }
        if data.count > 4096 { lines.append("… \(data.count - 4096) more bytes") }
        return lines.joined(separator: "\n")
    }
}
