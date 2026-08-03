import FountainKit
import SwiftUI

struct SettingsView: View {
    @AppStorage(PrefKey.editorFontSize) private var editorFontSize = EditorTypeSize.default

    /// Highland's PDFs measure 7.1904pt per character. A mismatch means
    /// exported pages will not line up with theirs, so it is shown rather than
    /// assumed.
    private var advanceMatchesHighland: Bool {
        abs(ScreenplayFont.measuredAdvance() - PageLayout.letter.characterWidth) < 0.01
    }

    private var resolvedSize: Double { EditorTypeSize.resolve(editorFontSize) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Editor type size") {
                    HStack(spacing: 10) {
                        Slider(
                            value: $editorFontSize,
                            in: EditorTypeSize.range,
                            step: 1
                        )
                        .frame(width: 160)
                        .accessibilityIdentifier("settings.editorFontSize")

                        Text("\(Int(resolvedSize)) pt")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                            .foregroundStyle(.secondary)

                        Button("Reset") { editorFontSize = EditorTypeSize.default }
                            .controlSize(.small)
                            .disabled(resolvedSize == EditorTypeSize.default)
                    }
                }

                sample
            } header: {
                Text("Editor")
            } footer: {
                Text(
                    "Affects only what you type on. Pages, the preview, and exported "
                    + "PDFs are always set at 12 pt, so changing this cannot move a "
                    + "page break."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Typesetting") {
                LabeledContent("Screenplay font") {
                    if ScreenplayFont.isCourierPrimeAvailable {
                        Label("Courier Prime", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Courier New (fallback)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                LabeledContent("Character advance") {
                    Text(String(format: "%.4f pt", ScreenplayFont.measuredAdvance()))
                        .monospacedDigit()
                        .foregroundStyle(advanceMatchesHighland ? Color.secondary : Color.orange)
                }
                LabeledContent("Page", value: "US Letter · 55 lines")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .accessibilityIdentifier("settings.root")
    }

    /// Shows the columns moving with the type, which is the part that is easy to
    /// get wrong and hard to describe.
    private var sample: some View {
        let scale = resolvedSize / EditorTypeSize.default
        let font = Font.custom(ScreenplayFont.postScriptName, size: resolvedSize)
        return VStack(alignment: .leading, spacing: 2) {
            Text("INT. GLASS HOUSE - NIGHT").font(font).bold()
            Text("Rain maps the windows.").font(font)
            Text("MARA")
                .font(font)
                .padding(.leading, 141 * scale * 0.34)
            Text("We built a room with no shadows.")
                .font(font)
                .padding(.leading, 71 * scale * 0.34)
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
