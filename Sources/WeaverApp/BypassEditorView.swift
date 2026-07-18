import SwiftUI

/// Manage the bypass list: hosts here are tunnelled without decryption, so
/// pinned apps keep working and noisy hosts stay out of capture.
struct BypassEditorView: View {
    @EnvironmentObject var controller: CaptureController
    @Environment(\.dismiss) private var dismiss
    @State private var newPattern = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bypass list")
                .font(.headline)
            Text("Hosts here are tunnelled through without decryption — use it for pinned apps (so they keep working) and hosts you don't want to inspect. Wildcards like `*.apple.com` are supported.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("host or *.domain", text: $newPattern)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if controller.bypassList.isEmpty {
                Text("No bypassed hosts yet.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List {
                    ForEach(controller.bypassList, id: \.self) { pattern in
                        HStack {
                            Image(systemName: "lock.open").foregroundStyle(.secondary).font(.caption)
                            Text(pattern).font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Button {
                                controller.removeBypass(pattern)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: 140, maxHeight: 240)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func add() {
        controller.addBypass(newPattern)
        newPattern = ""
    }
}
