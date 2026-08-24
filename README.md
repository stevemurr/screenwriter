# Screenwriter

<p align="center">
  <img src="Resources/AppIcon/preview-1024.png" width="144" alt="Screenwriter app icon">
</p>

Screenwriter is a native macOS editor for writing, organizing, and producing
screenplays in [Fountain](https://fountain.io/). It combines a responsive,
screenplay-styled writing surface with structural navigation, a beat board,
production metadata, linting, page preview, and PDF output—while keeping the
underlying script readable by ordinary text tools.

## Features

- **Write in Fountain.** Screenplay elements are recognized and styled as they
  are typed without changing the source text. A slash-command menu inserts
  common elements such as scenes, characters, sections, notes, and page breaks.
- **Navigate the whole script.** Browse acts, sequences, scenes, and characters
  in the outline, filter them, and jump directly to the corresponding text.
- **Plan on a beat board.** View scenes as cards grouped by sequence and drag
  them to reorder the Fountain source with undo support.
- **Keep production context attached.** Edit title-page details and scene status,
  cast, location, schedule, and notes. Production data is stored in transparent
  JSON sidecars rather than embedded in the screenplay text.
- **Preview, print, and export consistently.** The on-screen page preview, PDF
  export, and printing all use the same paginator and bundled Courier Prime
  fonts, with layout tuned against Highland output.
- **Catch formatting problems early.** Lint warnings and suggestions identify
  ambiguous or non-standard Fountain. Safe fixes can be applied individually or
  automatically without touching the line currently being written.
- **Bring existing work with you.** Open plain `.fountain` files and import
  `.highland` documents without ever writing back to the original Highland file.

## Requirements

- macOS 27 or later
- Xcode 27 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

The app and its `FountainKit` engine have no third-party runtime dependencies.

## Build and run

From the repository root:

```bash
xcodegen generate
xcodebuild -project Screenwriter.xcodeproj -scheme Screenwriter -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Screenwriter.app
```

`Screenwriter.xcodeproj` is generated from `project.yml`. Regenerate it after
adding or removing source files, and make project-setting changes in
`project.yml` rather than in the generated project.

## Supported formats

| Format | Read | Write | Notes |
| --- | :---: | :---: | --- |
| `.fountain` | Yes | Yes | Plain-text screenplay; production metadata is saved beside it as `<name>.screenwriter.json`. |
| `.screenplay` | Yes | Yes | An uncompressed TextBundle package containing Fountain, metadata, and preserved sidecars. It remains friendly to git, search tools, and file synchronization. |
| `.highland` | Yes | No | Imported as a new draft. The original bundle is always treated as read-only. |
| `.pdf` | — | Export | Generated from the same pagination model used by preview and print. |

## Testing

Run the platform-independent parser, pagination, lint, metadata, bundle, and
import tests with Swift Package Manager:

```bash
swift test --package-path Packages/FountainKit
```

Run the macOS app unit and integration tests with Xcode:

```bash
xcodegen generate
xcodebuild -project Screenwriter.xcodeproj -scheme Screenwriter \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build -only-testing:ScreenwriterTests test
```

The UI test target must be run in an isolated macOS VM because XCUITest takes
control of the host mouse and keyboard. See [CLAUDE.md](CLAUDE.md) for the
repository's VM workflow and detailed engineering constraints.

## Highland migration tool

`FountainKit` includes `fountain-migrate`, a command-line utility for inspecting
a screenplay library, profiling the parser, and converting Highland documents.
Start every migration with a dry run:

```bash
swift run -c release --package-path Packages/FountainKit fountain-migrate \
  migrate --dry-run /path/to/screenplays
```

Re-run without `--dry-run` to create `.screenplay` packages beside the source
files. Existing output is never overwritten, and `.highland` originals are only
read. Use `--plain` to create bare `.fountain` files instead, or
`--keep-revisions` to preserve Highland's opaque revision archive.

Other commands:

```bash
# Parse every Fountain file under a path and summarize the corpus.
swift run -c release --package-path Packages/FountainKit fountain-migrate report /path/to/screenplays

# Measure parser performance for one screenplay.
swift run -c release --package-path Packages/FountainKit fountain-migrate profile /path/to/script.fountain
```

## Architecture

```text
Packages/FountainKit/   UI-independent screenplay engine
  Parse/                Fountain parsing, completion, and live classification
  Model/                Parsed script, elements, title page, and scene reordering
  Paginate/             Page layout, line wrapping, and pagination
  Render/               PDF rendering
  Lint/                 Diagnostics and automatic fixes
  Bundle/               TextBundle and Highland import
  Metadata/             Production sidecars and scene identity resolution
  Sources/fountain-migrate/
                        Corpus reporting, profiling, and migration CLI

Sources/                Native macOS application
  App/                  AppKit lifecycle and menus
  Document/             NSDocument integration, models, save, print, and export
  Editor/               TextKit 2 editing and live styling
  Outline/              Structural navigator and diagnostics
  BeatBoard/            Scene-card planning and reordering
  Preview/              Paginated screenplay preview
  Inspector/            Title-page and scene production metadata
  Settings/             Editor, lint, and typesetting preferences
```

The boundary is deliberate: `FountainKit` contains the screenplay logic and can
be tested quickly without launching AppKit, SwiftUI, or Xcode. The application
uses an AppKit `NSDocument` lifecycle, a TextKit 2 editor, and SwiftUI views.

## Fonts

Courier Prime is bundled for stable screenplay metrics and is licensed under
the SIL Open Font License. See [Resources/Fonts/OFL.txt](Resources/Fonts/OFL.txt).
