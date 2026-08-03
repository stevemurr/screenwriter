import FountainKit
import SwiftUI

/// A read-only rendering of the script at screenplay indents.
///
/// Continuous for now — real US-Letter pagination, the Page/Continuous toggle,
/// `(MORE)`/`(CONT'D)` splits, and page numbers arrive in M5 with the
/// `Paginator`. Everything here already uses the measured Highland geometry from
/// `PageLayout`, so pagination slots in rather than replacing this.
struct ContinuousPreview: View {
    let script: ParsedScript
    private let layout = PageLayout.letter

    /// Notes, synopses, sections and boneyard follow Highland's saved print
    /// settings: sections print, synopses and notes do not.
    private var printable: [Element] {
        script.elements.filter { element in
            switch element.kind {
            case .synopsis, .note, .boneyard: return false
            case .blank: return false
            default: return !element.text.isEmpty
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "PAGE PREVIEW") {
                Text("Continuous")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(printable.enumerated()), id: \.offset) { _, element in
                        PreviewLine(element: element, layout: layout)
                    }
                }
                .frame(width: layout.rightEdge - layout.actionLeft, alignment: .leading)
                .padding(.vertical, 36)
                .padding(.horizontal, 32)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .accessibilityIdentifier("preview.continuous")
        }
    }
}

private struct PreviewLine: View {
    let element: Element
    let layout: PageLayout

    var body: some View {
        Text(displayText)
            .font(.custom(fontName, size: layout.fontSize))
            .fontWeight(element.kind == .sceneHeading ? .bold : .regular)
            .frame(
                maxWidth: .infinity,
                alignment: alignment
            )
            .padding(.leading, layout.leftEdge(for: element.kind) - layout.actionLeft)
            .padding(.trailing, layout.rightEdge - layout.rightEdge(for: element.kind))
            .padding(.top, topPadding)
    }

    /// Screenplay convention is uppercase headings and cues, and the corpus
    /// already types them that way. Uppercasing here is display-only and never
    /// touches the source.
    private var displayText: String {
        switch element.kind {
        case .sceneHeading, .character, .transition:
            return element.text.uppercased()
        default:
            return element.text
        }
    }

    private var fontName: String {
        ScreenplayFont.isCourierPrimeAvailable ? "CourierPrime" : "Courier New"
    }

    private var alignment: Alignment {
        switch element.kind {
        case .transition: return .trailing
        case .centered, .pageBreak: return .center
        default: return .leading
        }
    }

    /// A blank line before anything that starts a new beat.
    private var topPadding: CGFloat {
        switch element.kind {
        case .sceneHeading: return layout.lineHeight * 2
        case .action, .character, .transition, .section: return layout.lineHeight
        default: return 0
        }
    }
}
