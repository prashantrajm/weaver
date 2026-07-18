import SwiftUI
import WeaverCore
import UniformTypeIdentifiers

/// Bottom status bar: full-text filter, selection count, throughput, and HAR
/// export (M1.3 / M1.5).
struct StatusBar: View {
    @EnvironmentObject var controller: CaptureController
    @Binding var searchText: String
    let visibleCount: Int
    let totalCount: Int

    @State private var isExporting = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
            TextField("Filter by URL, host, method…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(maxWidth: 320)

            Divider().frame(height: 14)

            Text("\(visibleCount)/\(totalCount) shown")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Label(byteRate(controller.bytesIn), systemImage: "arrow.down")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            Label(byteRate(controller.bytesOut), systemImage: "arrow.up")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)

            Divider().frame(height: 14)

            Button {
                isExporting = true
            } label: {
                Label("Export HAR", systemImage: "square.and.arrow.up")
                    .font(.system(size: 11))
            }
            .disabled(controller.flows.isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .fileExporter(
            isPresented: $isExporting,
            document: HARDocument(flows: controller.flows),
            contentType: .json,
            defaultFilename: "weaver-session"
        ) { _ in }
    }

    private func byteRate(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}
