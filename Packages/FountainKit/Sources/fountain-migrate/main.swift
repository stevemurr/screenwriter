import Foundation
import FountainKit

// Batch tool over a tree of screenplays.
//
// `report` works today and is how the parser is checked against the real corpus
// without launching the app. `migrate` (M2) converts `.highland` bundles into
// `.screenplay` packages; the Highland side is read-only by design, so the
// originals are never opened for writing.

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: fountain-migrate <command> [options] <path>

    commands:
      report <path>     Parse every .fountain under <path> and print a summary.

    options:
      --dry-run         Report what would change without writing anything.

    """.utf8))
    exit(2)
}

guard let command = arguments.first else { usage() }
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

    while let url = enumerator?.nextObject() as? URL {
        guard url.pathExtension == "fountain" else { continue }
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            print("  !! unreadable: \(url.lastPathComponent)")
            continue
        }
        let script = ScriptParser.parse(source)
        files += 1
        totalScenes += script.scenes.count
        totalSections += script.sections.count
        if script.titlePage != nil { withTitlePage += 1 }

        let name = url.lastPathComponent
        print("""
          \(name.padding(toLength: min(42, max(name.count, 42)), withPad: " ", startingAt: 0)) \
        \(String(format: "%4d", script.scenes.count)) scenes  \
        \(String(format: "%3d", script.sections.count)) top sections  \
        \(String(format: "%3d", script.characters.count)) chars  \
        \(script.titlePage != nil ? "title" : "     ")
        """)
    }

    print("""

    \(files) files · \(totalScenes) scenes · \(totalSections) top-level sections · \
    \(withTitlePage) with a title page
    """)

case "profile":
    // Splits parse time between line indexing and everything downstream, so a
    // slow parse can be attributed rather than guessed at.
    let source = try! String(contentsOf: URL(fileURLWithPath: root), encoding: .utf8)
    func time(_ iterations: Int, _ body: () -> Void) -> Double {
        body()
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { body() }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 / Double(iterations)
    }

    let bytes = source.utf8.count
    let indexing = time(20) { _ = LineIndex(source: source) }
    let whole = time(20) { _ = ScriptParser.parse(source) }
    let index = LineIndex(source: source)
    let trimming = time(20) {
        for line in index.lines { _ = line.trimmedRight }
    }

    print("""
    \(URL(fileURLWithPath: root).lastPathComponent) — \(bytes) bytes, \(index.count) lines

      LineIndex            \(String(format: "%7.2f", indexing)) ms
      trimmedRight (all)   \(String(format: "%7.2f", trimming)) ms
      full parse           \(String(format: "%7.2f", whole)) ms
      ─────────────────────────────
      downstream of index  \(String(format: "%7.2f", whole - indexing)) ms
      throughput           \(String(format: "%7.2f", Double(bytes) / whole / 1000)) MB/s
    """)

case "migrate":
    FileHandle.standardError.write(Data("migrate lands in M2 — see the plan.\n".utf8))
    exit(1)

default:
    usage()
}
