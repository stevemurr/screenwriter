import FountainKit
import SwiftUI

struct SettingsView: View {

    /// Highland's PDFs measure 7.1904pt per character. A mismatch means
    /// exported pages will not line up with theirs, so it is shown rather than
    /// assumed.
    private var advanceMatchesHighland: Bool {
        abs(ScreenplayFont.measuredAdvance() - PageLayout.letter.characterWidth) < 0.01
    }

    var body: some View {
        Form {
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
                    // Highland's PDFs measure 7.1904pt per character. A mismatch
                    // here means exported pages will not line up with theirs.
                    Text(String(format: "%.4f pt", ScreenplayFont.measuredAdvance()))
                        .monospacedDigit()
                        .foregroundStyle(advanceMatchesHighland ? Color.secondary : Color.orange)
                }
                LabeledContent("Page", value: "US Letter · 55 lines")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
        .accessibilityIdentifier("settings.root")
    }
}
