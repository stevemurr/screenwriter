import Foundation
import Testing
@testable import FountainKit

/// `directoryWrapper()` is what `NSDocument.fileWrapper(ofType:)` calls, so it
/// runs on **every save**, not once at import. That is what makes its shape
/// worth pinning: a folder of production stills inside a `.screenplay` is an
/// ordinary thing for a writer to have, and the cost of writing one has to grow
/// with the number of files rather than with their square.
///
/// The suite is deliberately frugal: swift-testing runs suites concurrently, so
/// CPU spent here is CPU taken from every other suite's measurement. That is
/// also why the quadratic below is proved by *counting* the work rather than by
/// timing it — an exact count costs nothing and does not depend on the machine.
@Suite("TextBundle writing")
struct TextBundleWriteTests {

    /// Milliseconds of CPU actually spent on this thread — the same measure
    /// `ScriptParserPerformanceTests` uses, and for the same reason:
    /// swift-testing runs suites concurrently, so wall clock would report how
    /// busy the machine was rather than how much work this did.
    private static func cpuMilliseconds(_ body: () -> Void) -> Double {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        body()
        return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000
    }

    private static func best(_ rounds: Int, _ body: () -> Void) -> Double {
        body()
        return (0..<rounds).map { _ in cpuMilliseconds(body) }.min() ?? .infinity
    }

    /// A bundle with `count` files sharing one subdirectory — the shape that
    /// used to be quadratic. Built outside every timed block: assembling the
    /// dictionary is itself linear work and would dilute the signal.
    private static func bundle(filesInOneFolder count: Int) -> TextBundle {
        var extras: [String: Data] = [:]
        for index in 0..<count {
            extras["assets/still-\(index).png"] = Data(repeating: 7, count: 64)
        }
        return TextBundle(text: "INT. ROOM - DAY\n", extras: extras)
    }

    // MARK: - Shape

    @Test("Writing a folder costs its file count, not its square")
    func writingAFolderIsLinear() throws {
        let few = Self.bundle(filesInOneFolder: 128)
        let many = Self.bundle(filesInOneFolder: 512)

        let fewMs = Self.best(9) { _ = try? few.directoryWrapper() }
        let manyMs = Self.best(9) { _ = try? many.directoryWrapper() }

        // Four times the files. Linear predicts ×4, quadratic predicts ×16.
        // Measured on this machine, release, across exactly this pair: ×3.5 as
        // written, ×14.7 for the shape it replaced. Eight sits between them
        // with room on both sides, so this catches the regression without
        // being a stopwatch.
        let ratio = manyMs / fewMs
        #expect(
            ratio < 8,
            """
            512 files took \(String(format: "%.2f", manyMs))ms against \
            \(String(format: "%.2f", fewMs))ms for 128 — ×\(String(format: "%.1f", ratio)). \
            Writing a folder has gone superlinear again; something is rebuilding the \
            folder's FileWrapper once per file.
            """
        )
    }

    /// Reproduces the algorithm this replaced and shows it doing quadratic work.
    ///
    /// Without this, "linear" above could go on passing against a rewrite that
    /// was never fast, and nobody would know what the bound was protecting.
    /// `FileWrapper(directoryWithFileWrappers:)` takes a **complete** dictionary
    /// of children, so growing a folder a file at a time means constructing that
    /// folder once per file: 1 + 2 + … + n children handed over to place n
    /// files. Counting them rather than timing them makes this exact, machine-
    /// independent, and cheap enough to run beside every other suite.
    @Test("The rebuild-per-file shape it replaced really is quadratic")
    func theOldShapeWasQuadratic() throws {
        /// The algorithm as it shipped, with one line added: a tally of every
        /// child `FileWrapper(directoryWithFileWrappers:)` was handed.
        func legacyWrapper(_ bundle: TextBundle, childrenBuilt: inout Int) -> FileWrapper {
            func insert(
                _ wrapper: FileWrapper,
                named name: String,
                path: [String],
                into children: inout [String: FileWrapper]
            ) {
                guard let head = path.first else {
                    wrapper.preferredFilename = name
                    children[name] = wrapper
                    return
                }
                var nested = children[head]?.fileWrappers ?? [:]
                insert(wrapper, named: name, path: Array(path.dropFirst()), into: &nested)
                childrenBuilt += nested.count                       // ← the tally
                let directory = FileWrapper(directoryWithFileWrappers: nested)
                directory.preferredFilename = head
                children[head] = directory
            }

            var children: [String: FileWrapper] = [:]
            children[bundle.textFileName] = FileWrapper(
                regularFileWithContents: Data(bundle.text.utf8)
            )
            children[TextBundle.infoFileName] = FileWrapper(
                regularFileWithContents: bundle.infoData ?? TextBundle.defaultInfoData()
            )
            for (path, data) in bundle.extras {
                var components = path.split(separator: "/").map(String.init)
                guard let filename = components.popLast() else { continue }
                var container = children
                insert(
                    FileWrapper(regularFileWithContents: data),
                    named: filename,
                    path: components,
                    into: &container
                )
                children = container
            }
            return FileWrapper(directoryWithFileWrappers: children)
        }

        for count in [32, 64, 128] {
            var childrenBuilt = 0
            _ = legacyWrapper(Self.bundle(filesInOneFolder: count), childrenBuilt: &childrenBuilt)
            #expect(
                childrenBuilt == count * (count + 1) / 2,
                "\(count) files cost \(childrenBuilt) child wrappers, not \(count * (count + 1) / 2)."
            )
        }
        // Doubling the files quadruples the work — 528, 2080, 8256 — which is
        // the definition of the problem, stated in units nobody has to time.

        // The current implementation builds each folder once, so it hands over
        // exactly the files it was given. Grounded against real time at a size
        // small enough to be a good neighbour: measured 6.40ms against 0.22ms
        // at 64 files, release. Five is a floor with room to spare.
        let sample = Self.bundle(filesInOneFolder: 64)
        var ignored = 0
        let legacy = Self.best(2) { _ = legacyWrapper(sample, childrenBuilt: &ignored) }
        let current = Self.best(5) { _ = try? sample.directoryWrapper() }
        #expect(
            legacy > current * 5,
            """
            Rebuilding the folder per file took \(String(format: "%.2f", legacy))ms \
            against \(String(format: "%.2f", current))ms — only \
            ×\(String(format: "%.1f", legacy / current)). If those are comparable, \
            the current implementation has regressed into the old shape.
            """
        )

        // And they agree on the tree, so the comparison is like for like.
        var built = 0
        let legacyTree = legacyWrapper(sample, childrenBuilt: &built)
        let currentTree = try sample.directoryWrapper()
        #expect(
            Set(legacyTree.fileWrappers?["assets"]?.fileWrappers?.keys ?? [:].keys)
                == Set(currentTree.fileWrappers?["assets"]?.fileWrappers?.keys ?? [:].keys)
        )
    }

    // MARK: - The tree it builds

    @Test("Nested paths rebuild as folders, however deep")
    func nestedPathsRebuild() throws {
        let bundle = TextBundle(
            text: "INT. ROOM - DAY\n",
            extras: [
                "assets/poster.png": Data([1]),
                "assets/stills/day-one/a.png": Data([2]),
                "assets/stills/day-one/b.png": Data([3]),
                "assets/stills/day-two/a.png": Data([4]),
                "bin/9.txt": Data([5]),
                "loose.json": Data([6])
            ]
        )
        let wrapper = try bundle.directoryWrapper()

        // Two files in the same deep folder is the case a rebuild-per-file
        // could silently drop, so it is asserted rather than assumed.
        let dayOne = try #require(
            wrapper.fileWrappers?["assets"]?
                .fileWrappers?["stills"]?
                .fileWrappers?["day-one"]?.fileWrappers
        )
        #expect(Set(dayOne.keys) == ["a.png", "b.png"])
        #expect(dayOne["a.png"]?.regularFileContents == Data([2]))
        #expect(dayOne["b.png"]?.regularFileContents == Data([3]))

        // Every node names itself, so writing it out cannot invent a filename.
        #expect(wrapper.fileWrappers?["assets"]?.preferredFilename == "assets")
        #expect(wrapper.fileWrappers?["assets"]?.fileWrappers?["stills"]?
            .preferredFilename == "stills")
        #expect(dayOne["a.png"]?.preferredFilename == "a.png")
        #expect(wrapper.fileWrappers?["loose.json"]?.preferredFilename == "loose.json")
        #expect(wrapper.fileWrappers?[bundle.textFileName]?.regularFileContents
            == Data(bundle.text.utf8))

        // And it round-trips: read the tree back and get the same bundle.
        let reread = try TextBundle(directory: wrapper)
        #expect(reread.text == bundle.text)
        #expect(reread.extras == bundle.extras)
    }

    /// A zip can name both `bin` and `bin/9.txt`; a filesystem cannot hold both,
    /// so one has to lose. Which one used to depend on dictionary order — the
    /// same bundle could write two different trees on two runs. It is the folder
    /// now, every time.
    @Test("A path that is both a file and a folder resolves to the folder")
    func fileAndFolderCollision() throws {
        let bundle = TextBundle(
            text: "x",
            extras: ["bin": Data([1]), "bin/9.txt": Data([2])]
        )
        for _ in 0..<20 {
            let wrapper = try bundle.directoryWrapper()
            let bin = try #require(wrapper.fileWrappers?["bin"])
            #expect(bin.isDirectory)
            #expect(bin.fileWrappers?["9.txt"]?.regularFileContents == Data([2]))
        }
    }

    /// The corpus's own bundles, written out and read back. The synthetic cases
    /// above pin the shape; this pins it against real files, including the
    /// nested `resources/`, `assets/` and `bin/` folders Highland writes.
    @Test("Every bundle in the library survives a write and a read")
    func corpusRoundTrip() throws {
        let bundles = try #require(
            HighlandCorpus.bundles,
            "Reference corpus not present on this machine."
        )
        var checked = 0
        var nested = 0
        for url in bundles {
            // One bundle in the library is genuinely corrupt; failing on it is
            // correct, and it is not what this test is about.
            guard let imported = try? HighlandBundle(contentsOf: url).textBundle() else {
                continue
            }
            let reread = try TextBundle(directory: imported.directoryWrapper())
            #expect(reread.text == imported.text, "\(url.lastPathComponent)")
            #expect(reread.textFileName == imported.textFileName, "\(url.lastPathComponent)")
            #expect(reread.infoData == imported.infoData, "\(url.lastPathComponent)")
            #expect(reread.extras == imported.extras, "\(url.lastPathComponent)")
            checked += 1
            if imported.extras.keys.contains(where: { $0.contains("/") }) { nested += 1 }
        }
        #expect(checked >= 50, "Only \(checked) bundles round-tripped.")
        #expect(nested >= 20, "Only \(nested) bundles exercised a nested path.")
    }
}
