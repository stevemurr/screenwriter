# Screenwriter

A native macOS screenplay editor for the Fountain format. Write in raw Fountain or
in a live screenplay-styled surface, see an instant page preview, export PDFs that
match Highland's typesetting, and migrate an existing `.highland` library into a
format git and Syncthing can actually read.

## Build & Run

When a UI test fails on a lookup, attach `app.debugDescription` and dump every
static text with its identifier (see `testDumpAccessibilityTree`) rather than
guessing at the query. One instrumented run answered what four fix-and-rerun
attempts did not. And when a fix does not take, check the fix actually landed
before forming the next hypothesis — a revert that only reverted the test side
cost three runs of debugging code that had never changed.

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

### Rule 9: An `NSViewRepresentable`'s inner view needs its own accessibility identity
`.accessibilityIdentifier` in SwiftUI labels the *wrapper*. The `NSTextView`
inside stays anonymous and is not in the accessibility tree at all, because
AppKit does not expose a TextKit 2 document view beneath a scroll view on its
own. Set the identifier and role on the view itself and make the host an
explicit group whose sole child is the editor — see `EditorHostView`. This is
covered by `EditorAccessibilityTests`, which runs on the host in milliseconds;
finding it through the VM cost a five-minute round trip.

### Rule 10: `.accessibilityIdentifier` on a SwiftUI `Text` erases its label
The status bar's readouts expose their identifiers and an **empty** label, and
adding an explicit `.accessibilityLabel` does not restore it. So a UI test can
never match those by their text, and VoiceOver announces nothing. Assert on the
sidebar's scene rows instead, which do carry their headings. If a status readout
ever has to be assertable, verify with `app.debugDescription` first rather than
assuming the identifier is enough.

### Rule 11: UI tests use the window the app opens at launch
Do not press ⌘N. Launch already opens one untitled screenplay, and a second
window means two status bars and two of everything else to match against.
Suppressing the launch document under test is worse still: with no window the
app never becomes active, so a later ⌘N window never takes key focus and
everything typed into it is silently lost.

### Rule 12: A window command must name the document it is for
Menu actions reach documents by posting a notification. Post it with the target
`ScreenplayModel` as the object and check it on receipt. A nil object reaches
every open `RootView`, so one ⌘⇧T opened a title-page sheet on every window.

### Rule 13: Parse leniently, lint loudly
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

Measured facts worth knowing: `anal-informant.fountain` is 3,581 lines with 95
`#N#`-numbered scenes and 40 sections; `THICK` forces essentially every line
(597 `!`, 402 `@`, 37 `.`) and lints completely clean; 39 `.highland` bundles
carry `text.fountain` and 19 carry the older `text.md`; the zips hold 344 stored
+ 308 deflated entries.

Things that were assumed and turned out to be wrong, so do not re-assume them:

- **The two Highland "generations" are not two shapes.** A document edited across
  versions carries both the `resources/` sidecars *and* the flat
  `sprints.json`/`characters.json`. Nothing branches on generation; the reader
  takes whatever is present. Payload name is independent of layout.
- **Print settings live in up to three places** — loose in `info.json`'s
  highland2 namespace, in its `.printOptions`, and in `printSettings`. Only 21 of
  59 bundles have `resources/settings.json` at all.
- **`templateName` means two different things.** In `info.json` it is the
  document template; in `printSettings` it is the print template. Only the first
  is carried.
- **The `.textbundle/` root name need not match the filename.** Highland
  truncates at the last dot, so `Anal Informant - 3.25.highland` wraps
  `Anal Informant - 3.textbundle/`. Derive it, never assume it.
- **One bundle in the library is genuinely corrupt.**
  `The Gig Economy/The Gig Economy Script.highland` was written back after a
  lossy UTF-8 round trip; 138 bytes became U+FFFD and every offset after them
  shifted. `/usr/bin/unzip` fails on it too. Failing loudly on it is correct.
- **Sections do not print.** Highland's own `resources/settings.json` says
  `printSections: true`, and across nineteen of the user's exports there is not a
  single printed section line. `PrintSettings.printSections` therefore defaults
  **off**. When a settings file and the exports disagree, the exports win — they
  are what the user actually looked at.
- **The column measures are not symmetric and not derivable.** Measured from the
  longest line Highland ever drew at each x: **63 / 34 / 29 (parentheticals hang
  to 27) / 55 for headings**. Deriving dialogue as inset symmetrically about the
  action column gives 35 — one too many — and re-wraps about one dialogue line in
  twelve.
- **`linesPerPage` is 55**, not 56. An earlier `+ 1` counted the first line twice.
- Six Trophy Boyz episodes write sluglines as `## N. EXT. RAVINE - DAY` — 42 of
  them, with **zero real scene headings in between**, so the parser sees no
  scenes at all and Highland prints none of them. This is what the
  `slugline-as-section` lint rule exists for, and it fires zero times on the
  loose `.fountain` files because every one of those episodes is a bundle.

`PageLayout` holds Highland's exact page geometry, measured from 48 of their
PDFs. It is the single source of truth for the styled editor, the preview, and
the PDF renderer. If they ever disagree, the preview stops predicting the export.
