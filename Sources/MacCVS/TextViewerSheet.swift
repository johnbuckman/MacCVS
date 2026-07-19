import SwiftUI

/// Read-only viewer for diff and log output, with simple diff syntax colouring.
struct TextViewerSheet: View {
    let title: String
    let text: String
    let isDiff: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                if isDiff {
                    diffColoured
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(width: 760, height: 560)
    }

    private var diffColoured: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, raw in
                let line = String(raw)
                Text(line.isEmpty ? " " : line)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(colour(for: line))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func colour(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .secondary }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        if line.hasPrefix("@@") { return .blue }
        if line.hasPrefix("Index:") || line.hasPrefix("===") { return .purple }
        return .primary
    }
}
