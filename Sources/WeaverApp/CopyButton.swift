import SwiftUI

/// A small copy-to-clipboard button that briefly shows a checkmark as feedback.
/// The text is provided lazily so it's only computed on tap.
struct CopyButton: View {
    let text: () -> String
    var help: String = "Copy"

    @State private var copied = false

    var body: some View {
        Button {
            let value = text()
            guard !value.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .foregroundStyle(copied ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
