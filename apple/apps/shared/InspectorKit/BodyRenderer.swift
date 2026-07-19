import Foundation
#if canImport(AppKit)
import AppKit
/// Platform image type so image previews share one code path (NSImage/UIImage).
public typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#endif

/// Shared, content-aware rendering of a message body so the on-screen view and
/// the copy button produce the exact same (beautified) text.
public enum BodyRenderer {

    public static func isImage(_ contentType: String?) -> Bool {
        (contentType ?? "").lowercased().contains("image")
    }

    public static func image(from data: Data) -> PlatformImage? {
        PlatformImage(data: data)
    }

    /// Beautified text for a body. JSON is pretty-printed (unless `raw`), other
    /// text types are shown as UTF-8, and binary falls back to a hex dump.
    public static func text(_ data: Data, contentType: String?, raw: Bool) -> String {
        let ct = (contentType ?? "").lowercased()
        if !raw, ct.contains("json"), let pretty = prettyJSON(data) {
            return pretty
        }
        if !raw, ct.contains("xml") || ct.contains("html"),
           let text = String(data: data, encoding: .utf8) {
            return prettyXML(text)
        }
        if ct.contains("json") || ct.contains("xml") || ct.contains("text")
            || ct.contains("javascript") || ct.contains("html") || ct.contains("form")
            || ct.isEmpty {
            if let text = String(data: data, encoding: .utf8) { return text }
        }
        return hexDump(data)
    }

    private static func prettyJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }

    /// Lightweight XML/HTML indenter — enough to make a one-line document
    /// readable without pulling in a full parser.
    private static func prettyXML(_ input: String) -> String {
        let normalized = input.replacingOccurrences(of: ">\\s*<", with: "><", options: .regularExpression)
        var out = ""
        var indent = 0
        let tokens = normalized.replacingOccurrences(of: "><", with: ">\n<").split(separator: "\n")
        for raw in tokens {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("</") { indent = max(0, indent - 1) }
            out += String(repeating: "  ", count: indent) + line + "\n"
            let isSelfContained = line.contains("</") || line.hasSuffix("/>")
                || line.hasPrefix("<?") || line.hasPrefix("<!")
            if line.hasPrefix("<"), !line.hasPrefix("</"), !isSelfContained { indent += 1 }
        }
        return out.trimmingCharacters(in: .newlines)
    }

    private static func hexDump(_ data: Data) -> String {
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
