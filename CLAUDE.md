# Screenwriter

A native macOS screenplay editor for the Fountain format. Write in raw Fountain or
in a live screenplay-styled surface, see an instant page preview, export PDFs that
match Highland's typesetting, and migrate an existing `.highland` library into a
format git and Syncthing can actually read.

## Build & Run

```bash
# Engine tests — seconds, no Xcode
swift test --package-path Packages/FountainKit

# Build and run the app
xcodegen generate
xcodebuild -project Screenwriter.xcodeproj -scheme Screenwriter \
  -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Screenwriter.app

# App unit tests — host-safe, the main scheme tests only the unit target
xcodebuild -project Screenwriter.xcodeproj -scheme Screenwriter \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build -only-testing:ScreenwriterTests test

# UI tests — VM ONLY. XCUITest seizes the host mouse and keyboard.
~/.claude/skills/vm-uitest/uitest.sh

# Parse the real corpus / profile the parser
swift run -c release --package-path Packages/FountainKit fountain-migrate \
  report ~/Code/github.com/stevemurr/screenplays
swift run -c release --package-path Packages/FountainKit fountain-migrate \
  profile "path/to/script.fountain"
```

`xcodegen generate` after adding or removing any source file — `.xcodeproj` is
generated and gitignored, and a new file is invisible to the build until then.

## Structure

```
Packages/FountainKit/     the screenplay engine — NO AppKit, NO SwiftUI
  Model/                  Element, ParsedScript, ScriptScene, TitlePage, SectionNode
  Parse/                  LineIndex, ScriptParser, TitlePageParser
  Paginate/               PageLayout (the measured Highland geometry)
  Bundle/                 TextBundle
  Sources/fountain-migrate/  CLI: report, profile, migrate
Sources/                  the app — SwiftUI hosted in AppKit
  App/                    main.swift, AppDelegate, MainMenu
  Document/               ScreenplayDocument (NSDocument), ScreenplayModel, WindowController
  Editor/                 FountainEditorSurface, EditorHostView, ElementStyler
  Outline/ Preview/ Settings/ Support/ UI/
```

The boundary is the point: the whole engine is testable with `swift test` in
seconds, with no UI, no Xcode, and no VM.

## Rules

Each of these was learned by something breaking. Do not undo one without
reproducing the failure it prevents.

### Rule 1: Never touch `textView.layoutManager`
Reading it once puts AppKit into TextKit 1 compatibility mode — silently,
permanently, with no error and no visible change beyond the incremental-layout
performance disappearing. Every geometry query goes through `textLayoutManager`.
**No test may assert on `layoutManager`.** This is why the line-number ruler
walks `enumerateTextLayoutFragments` and the scroll anchor is a character offset.

### Rule 2: The editing surface never mutates the user's bytes
Indents, colour, font, and dimmed forcing marks are all *attributes*. Nothing
uppercases, hides, or rewrites text in the storage. That is what keeps selection,
arrow keys, find, and copy/paste behaving normally. True mark-hiding would need
`NSTextContentStorageDelegate` paragraph substitution, which makes display
offsets diverge from storage offsets — deliberately deferred.

### Rule 3: Text substitutions stay off
`isAutomaticQuoteSubstitutionEnabled`, dash substitution, and text replacement
are all disabled on the text view. The parser keys on the first character of a
line (`.`, `@`, `!`, `>`, `#`, `=`, `~`), and macOS would rewrite quotes and
dashes underneath it.

### Rule 4: No `String.count`, `Character` iteration, or `range(of:)` in the parser's per-line path
They walk grapheme clusters. An ungated `raw.count >= 3` alone cost 6ms on a
91 KB script. Use `utf8.count`, iterate `.utf8`, and use `markerOffset` for
literal markers. `LineIndex.Line.isBlank` is stored, not computed, because
classification asks about each line and both its neighbours.

### Rule 5: Parsing runs off the main actor, behind a debounce
A full reparse of the largest script in the reference library is ~15ms. Editing
schedules it; it never runs inline in `didSet`. `load()` parses synchronously so
a document opens with its outline populated. Consumers must tolerate a parse
result arriving slightly after the text — always check the source still matches
before applying a result.

### Rule 6: `.highland` is read-only, forever
The reference library holds 59 of them and they are irreplaceable. The app
imports and migrates; it never opens one for writing. `fileWrapper(ofType:)`
throws for that type, and a test asserts it.

### Rule 7: Title pages are parsed only at the head of the document
`CUT TO:` appears 48 times in the corpus, and `CLOSE ON:`, `TITLE CARD:`,
`WIDER:` and `TODO:` all match a naive `Key:` pattern. The first key must come
from `titlePageOpeningKeys`; after that, custom keys are accepted. Only 7 of 17
scripts have a title page at all — never infer one.

### Rule 8: AppKit owns the app lifecycle, not SwiftUI
`main.swift` calls `NSApplicationMain`. A SwiftUI `App` with only a `Settings`
scene launches fine but `NSDocumentController` never receives the open-file
event and no document window is ever created. SwiftUI still draws every view,
inside `NSHostingView` under an AppKit window. The menu bar is built in
`MainMenu.swift` because there is no NIB and no scene to generate one.

### Rule 9: Parse leniently, lint loudly
Real scripts contain en-dash sluglines, lowercase headings, headings with no
trailing period, parentheticals on the cue line, and `.`/`>` used as generic
force marks. The parser accepts all of it. Ambiguity is reported by the lint
layer, separately and testably — never by refusing to parse.

## Conventions

- `@Observable`, never `ObservableObject`. Pass models to sub-views as plain
  `var`; use `@State` when owning one, `@Bindable` for `$` binding syntax.
- `@MainActor` on UI-touching state. No `SWIFT_STRICT_CONCURRENCY` setting;
  Swift 5 language mode with `@MainActor` discipline.
- Colours come from system colours via `Style` in `DesignSystem.swift`, so the
  app tracks light and dark rather than hard-coding either.
- No `print`. Add a category to `Log` in `Support/Log.swift`.
- Zero external dependencies. Reading the zip inside a `.highland` is ~180 lines
  against the system `Compression` framework — check here before adding a first
  dependency.
- FountainKit uses swift-testing (`import Testing`); the app targets use XCTest.
- Accessibility identifiers on anything a UI test touches, dotted:
  `editor.surface`, `scenes.list`, `status.words`.

## Reference corpus

`~/Code/github.com/stevemurr/screenplays` — 17 `.fountain`, 59 `.highland`,
50 Highland-exported PDFs. This is the regression suite, not sample data. Tests
that need it skip when it is absent rather than failing.

Measured facts worth knowing: `anal-informant.fountain` is 91 KB with 95
`#N#`-numbered scenes and 40 sections; `THICK` forces essentially every line
(597 `!`, 402 `@`, 37 `.`); 39 `.highland` bundles carry `text.fountain` and 19
carry the older `text.md`; the zip inside is 344 stored + 304 deflated entries.
Six Trophy Boyz episodes write sluglines as `## 1. EXT. RAVINE - DAY`, which
Highland silently drops from the PDF — the highest-value lint rule to write.

`PageLayout` holds Highland's exact page geometry, measured from 48 of their
PDFs. It is the single source of truth for the styled editor, the preview, and
the PDF renderer. If they ever disagree, the preview stops predicting the export.
