import FountainKit
import SwiftUI

/// The lint results, as a list under the editor.
///
/// Everything here is advice, never an error: the parser accepts all of it and
/// the document is valid either way. The messages say what will *happen* — "this
/// will not appear in the PDF as a scene" — rather than what the spec says,
/// because the writer cares about the output, not the grammar.
struct DiagnosticsPane: View {
    let diagnostics: [Diagnostic]
    let onSelect: (Diagnostic) -> Void
    let onFix: (Diagnostic) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if diagnostics.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text("Nothing to flag.")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: 34)
            } else {
                List(diagnostics) { diagnostic in
                    DiagnosticRow(diagnostic: diagnostic, onFix: onFix)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(diagnostic) }
                }
                .listStyle(.plain)
                .frame(height: 160)
            }
        }
        .background(Color(nsColor: Style.paneBackground))
        .accessibilityIdentifier("diagnostics.pane")
    }
}

private struct DiagnosticRow: View {
    let diagnostic: Diagnostic
    let onFix: (Diagnostic) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: diagnostic.severity == .warning
                  ? "exclamationmark.triangle.fill"
                  : "lightbulb")
                .foregroundStyle(diagnostic.severity == .warning ? .orange : .secondary)
                .font(.system(size: 11))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(diagnostic.message)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Line \(diagnostic.lineIndex + 1) · \(diagnostic.rule.title)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            if diagnostic.isFixable {
                Button("Fix") { onFix(diagnostic) }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 3)
    }
}

/// The summary shown in the status bar, which doubles as the pane's toggle.
struct DiagnosticsSummary: View {
    let warnings: Int
    let suggestions: Int
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                if warnings > 0 {
                    Label("\(warnings)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if suggestions > 0 {
                    Label("\(suggestions)", systemImage: "lightbulb")
                        .foregroundStyle(.secondary)
                }
                if warnings == 0, suggestions == 0 {
                    Label("Clean", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide the lint results" : "Show the lint results")
        .accessibilityIdentifier("status.diagnostics")
    }
}
