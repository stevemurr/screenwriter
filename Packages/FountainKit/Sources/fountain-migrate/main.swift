import Foundation
import FountainKit

// Batch tool over a tree of screenplays.
//
// `report` is how the parser is checked against the real corpus without
// launching the app. `migrate` converts `.highland` bundles into `.screenplay`
// packages; the Highland side is read-only by design, so the originals are
// never opened for writing.

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: fountain-migrate <command> [options] <path>

    commands:
      report <path>              Parse every .fountain under <path> and summarise.
      profile <file>             Time the parser on one script.
      migrate [options] <path>   Convert Highland documents into .screenplay
                                 packages, next to the originals.

    migrate options:
      --dry-run          Print exactly what would be written, and write nothing.
                         Start here — every run without it writes files.
      --plain            Write a bare .fountain file instead of a .screenplay
                         package. Loses every sidecar the bundle carried.
      --keep-revisions   Carry Highland's revisions/current.json across. It is a
                         base64 NSKeyedArchiver blob, dropped by default.

    <path> may be one file or a tree. Existing output is never overwritten —
    it is skipped and reported. `.highland` originals are only ever read.

    """.utf8))
    exit(2)
}

guard let command = arguments.first else { usage() }
let flags = Set(arguments.filter { $0.hasPrefix("--") })
let paths = arguments.dropFirst().filter { !$0.hasPrefix("--") }
guard let root = paths.first else { usage() }

switch command {
case "report":
    let rootURL = URL(fileURLWithPath: root)
    let enumerator = FileManager.default.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )
    var files = 0
    var totalScenes = 0
    var totalSections = 0
    var withTitlePage = 0
    var totalWarnings = 0
    var totalSuggestions = 0

    while let url = enumerator?.nextObject() as? URL {
        guard url.pathExtension == "fountain" else { continue }
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            print("  !! unreadable: \(url.lastPathComponent)")
            continue
        }
        let script = ScriptParser.parse(source)
        // The report exists to survey the library before migrating it, and the
        // linter is the half that finds anything worth acting on — the six
        // `## 1. EXT. RAVINE - DAY` sluglines-as-sections that Highland drops
        // silently from its PDFs are a lint finding, not a scene count. It was
        // parsing and then not asking.
        let diagnostics = Linter.lint(script)
        let warnings = diagnostics.count { $0.severity == .warning }
        let suggestions = diagnostics.count { $0.severity == .suggestion }
        files += 1
        totalScenes += script.scenes.count
        totalSections += script.sections.count
        totalWarnings += warnings
        totalSuggestions += suggestions
        if script.titlePage != nil { withTitlePage += 1 }

        let name = url.lastPathComponent
        print("""
          \(name.padding(toLength: min(42, max(name.count, 42)), withPad: " ", startingAt: 0)) \
        \(String(format: "%4d", script.scenes.count)) scenes  \
        \(String(format: "%3d", script.sections.count)) top sections  \
        \(String(format: "%3d", script.characters.count)) chars  \
        \(script.titlePage != nil ? "title" : "     ")  \
        \(warnings > 0 ? String(format: "%3d warn", warnings) : "       ")  \
        \(suggestions > 0 ? String(format: "%3d sugg", suggestions) : "")
        """)
    }

    print("""

    \(files) files · \(totalScenes) scenes · \(totalSections) top-level sections · \
    \(withTitlePage) with a title page
    \(totalWarnings) warnings · \(totalSuggestions) suggestions
    """)

case "profile":
    // Splits parse time between line indexing and everything downstream, so a
    // slow parse can be attributed rather than guessed at.
    let source = try! String(contentsOf: URL(fileURLWithPath: root), encoding: .utf8)
    // CPU time, not wall clock. CLAUDE.md points at this command as the way to
    // profile the parser, so a number inflated by whatever else the machine is
    // doing is a documented path to a wrong conclusion — up to 8x on a busy
    // machine. Best-of-N rather than mean, for the same reason.
    func time(_ iterations: Int, _ body: () -> Void) -> Double {
        body()
        return (0..<iterations).map { _ -> Double in
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            body()
            return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000
        }.min() ?? .infinity
    }

    let bytes = source.utf8.count
    let indexing = time(20) { _ = LineIndex(source: source) }
    let whole = time(20) { _ = ScriptParser.parse(source) }
    let index = LineIndex(source: source)
    let trimming = time(20) {
        for line in index.lines { _ = line.trimmedRight }
    }

    // Derived counts read by the status bar. Separate from the parse because
    // they are computed per reparse rather than per keystroke, and because a
    // count is the kind of thing that looks free and is not.
    let script = ScriptParser.parse(source)
    let counting = time(20) { _ = script.wordCount }

    print("""
    \(URL(fileURLWithPath: root).lastPathComponent) — \(bytes) bytes, \(index.count) lines

      LineIndex            \(String(format: "%7.2f", indexing)) ms
      trimmedRight (all)   \(String(format: "%7.2f", trimming)) ms
      full parse           \(String(format: "%7.2f", whole)) ms
      ─────────────────────────────
      downstream of index  \(String(format: "%7.2f", whole - indexing)) ms
      throughput           \(String(format: "%7.2f", Double(bytes) / whole / 1000)) MB/s

      wordCount            \(String(format: "%7.2f", counting)) ms  (\(script.wordCount) words)
    """)

case "migrate":
    // Reads `.highland` and loose `.fountain`, writes `.screenplay` beside them.
    // Rule 6: the only call made against a `.highland` is `Data(contentsOf:)`.
    let dryRun = flags.contains("--dry-run")
    let plain = flags.contains("--plain")
    let keepRevisions = flags.contains("--keep-revisions")
    let outputExtension = plain ? "fountain" : "screenplay"

    let rootURL = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
    var sources: [URL] = []
    var isDirectory: ObjCBool = false
    FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory)

    if isDirectory.boolValue {
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let url = enumerator?.nextObject() as? URL {
            if ["highland", "fountain"].contains(url.pathExtension) { sources.append(url) }
        }
        // Grouped by output name, `.highland` first: `Clean Break/` holds both
        // `Clean Break.highland` and `Clean Break.fountain`, and the bundle is
        // the richer source — it brings every sidecar with it.
        sources.sort {
            let left = $0.deletingPathExtension().path
            let right = $1.deletingPathExtension().path
            if left != right { return left < right }
            return $0.pathExtension == "highland"
        }
    } else {
        sources = [rootURL]
    }

    print(dryRun
        ? "dry run — reading \(sources.count) file(s), writing nothing"
        : "writing .\(outputExtension) beside \(sources.count) source file(s)")
    print("")

    var converted = 0
    var skipped: [(String, String)] = []
    var failed: [(String, String)] = []
    var legacy = 0
    var current = 0
    var revisionBytesDropped = 0
    // A dry run has to predict the real run exactly, and two sources can want
    // the same output: `Clean Break/` holds both `Clean Break.highland` and
    // `Clean Break.fountain`. Without this the dry run promises 2 conversions
    // and the real run does 1 and skips 1.
    var claimed: Set<String> = []

    /// Left-aligned to a fixed width so the columns line up over 59 rows.
    func column(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    for source in sources {
        let name = source.lastPathComponent
        let output = source.deletingPathExtension().appendingPathExtension(outputExtension)

        if output == source {
            skipped.append((name, "already .\(outputExtension)"))
            continue
        }
        if FileManager.default.fileExists(atPath: output.path) {
            skipped.append((name, "\(output.lastPathComponent) already exists"))
            continue
        }
        if !claimed.insert(output.path).inserted {
            skipped.append((name, "another source already claims \(output.lastPathComponent)"))
            continue
        }

        do {
            let bundle: TextBundle
            var note = ""
            if source.pathExtension == "highland" {
                let result = try HighlandBundle(contentsOf: source)
                    .imported(keepingOpaqueState: keepRevisions)
                bundle = result.bundle
                if result.generation == .legacy { legacy += 1 } else { current += 1 }
                revisionBytesDropped += result.droppedBytes
                note = "\(column(result.bundle.textFileName, 14))"
                    + "\(column(result.generation.rawValue, 8))"
                    + String(format: "%3d extras", result.bundle.extras.count)
                if result.droppedBytes > 0 {
                    note += String(format: "  −%d KB revisions", result.droppedBytes / 1024)
                }
                for problem in result.unreadable {
                    note += "\n      !! \(problem.path): \(problem.reason)"
                }
            } else {
                let text = try String(contentsOf: source, encoding: .utf8)
                bundle = TextBundle(text: text)
                note = column("text.fountain", 14) + column("plain", 8)
            }

            if !dryRun {
                if plain {
                    try Data(bundle.text.utf8).write(to: output, options: .withoutOverwriting)
                } else {
                    try bundle.directoryWrapper().write(
                        to: output,
                        options: .atomic,
                        originalContentsURL: nil
                    )
                }
            }
            converted += 1
            print("  \(column(name, 44)) → \(column(output.lastPathComponent, 40)) \(note)")
        } catch {
            // Release the name so a sibling source can still take it.
            claimed.remove(output.path)
            failed.append((name, error.localizedDescription))
        }
    }

    if !skipped.isEmpty {
        print("\nskipped:")
        for (name, reason) in skipped { print("  \(column(name, 44)) \(reason)") }
    }
    if !failed.isEmpty {
        print("\nfailed:")
        for (name, reason) in failed { print("  \(column(name, 44)) \(reason)") }
    }

    print("""

    \(converted) \(dryRun ? "would convert" : "converted") · \(skipped.count) skipped · \
    \(failed.count) failed
    \(legacy) legacy-layout bundles · \(current) current-layout bundles · \
    \(revisionBytesDropped / 1024) KB of Highland revision state dropped
    """)
    if dryRun && converted > 0 {
        print("nothing was written — re-run without --dry-run to migrate")
    }
    exit(failed.isEmpty ? 0 : 1)

default:
    usage()
}
