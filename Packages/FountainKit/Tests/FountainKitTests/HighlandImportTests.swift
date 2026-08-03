import Foundation
import Testing
@testable import FountainKit

/// Import is the one feature that touches irreplaceable files, so it is tested
/// against the irreplaceable files — 59 `.highland` bundles at
/// `~/Code/github.com/stevemurr/screenplays`, spanning two generations of
/// Highland's own format. Every test here skips when that library is absent.
@Suite("Highland import")
struct HighlandImportTests {

    // MARK: - Rule 6

    /// The rule that matters most: importing reads and only reads. If this ever
    /// fails, 59 irreplaceable documents are at risk.
    @Test("Importing never modifies the original")
    func originalIsUntouched() throws {
        let url = try #require(HighlandCorpus.bundle(named: "Clean Break.highland"))
        let attributes = FileManager.default.attributeKeys(for: url)

        _ = try HighlandBundle(contentsOf: url).imported()
        _ = try HighlandBundle(contentsOf: url).imported(keepingOpaqueState: true)

        #expect(FileManager.default.attributeKeys(for: url) == attributes)
    }

    // MARK: - Byte equality against a reference implementation

    /// The proof that the hand-rolled zip reader is right: extract the payload
    /// again with `/usr/bin/unzip`, a completely independent implementation,
    /// and demand identical bytes. Sampled across both generations and both
    /// compression methods.
    @Test("Payload bytes match /usr/bin/unzip exactly")
    func matchesUnzip() throws {
        let sample = try #require(Self.sample, "Reference corpus not present on this machine.")
        try #require(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/unzip"),
            "No /usr/bin/unzip to check against."
        )
        #expect(sample.count >= 8)

        var generations: Set<HighlandBundle.Generation> = []
        var methods: Set<UInt16> = []

        for url in sample {
            let highland = try HighlandBundle(contentsOf: url)
            let result = try highland.imported()
            generations.insert(result.generation)

            let path = highland.rootPrefix + result.bundle.textFileName
            let entry = try #require(highland.archive[path], "\(url.lastPathComponent): \(path)")
            methods.insert(entry.compressionMethod)

            let ours = try highland.archive.data(for: entry)
            let theirs = try #require(
                Self.unzip(entry: path, from: url),
                "unzip failed on \(url.lastPathComponent)"
            )
            #expect(ours == theirs, "\(url.lastPathComponent) differs from unzip")
            // And the decode to `String` is lossless on the way through.
            #expect(Data(result.bundle.text.utf8) == theirs, "\(url.lastPathComponent) decode")
        }

        #expect(generations == [.legacy, .current], "Sample must span both generations")
        #expect(methods == [0, 8], "Sample must span both compression methods")
    }

    // MARK: - Both generations

    @Test("The legacy layout imports, keeping text.md")
    func legacyGeneration() throws {
        let url = try #require(HighlandCorpus.bundle(named: "Clean Break.highland"))
        let result = try HighlandBundle(contentsOf: url).imported()

        #expect(result.generation == .legacy)
        #expect(result.bundle.textFileName == "text.md")
        #expect(result.bundle.text.hasPrefix("TITLE:\n\tClean Break"))

        // Sidecars are bundle-relative: the `*.textbundle/` wrapper is gone.
        #expect(result.bundle.extras["resources/settings.json"] != nil)
        #expect(result.bundle.extras["scratchpad.txt"] != nil)
        #expect(!result.bundle.extras.keys.contains { $0.contains(".textbundle/") })
    }

    @Test("The current layout imports, keeping text.fountain")
    func currentGeneration() throws {
        let url = try #require(HighlandCorpus.bundle(named: "Episode 1.highland"))
        let result = try HighlandBundle(contentsOf: url).imported()

        #expect(result.generation == .current)
        #expect(result.bundle.textFileName == "text.fountain")
        #expect(result.bundle.extras.keys.sorted()
            == ["characters.json", "navigatorFilters.json", "sprints.json"])
    }

    /// Highland truncates the wrapper name at the last dot, so the root inside
    /// the zip need not match the filename. It has to be derived.
    @Test("The textbundle root is derived, not assumed from the filename")
    func rootPrefixIsDerived() throws {
        let url = try #require(HighlandCorpus.bundle(named: "Anal Informant - 3.25.highland"))
        let highland = try HighlandBundle(contentsOf: url)
        #expect(highland.rootPrefix == "Anal Informant - 3.textbundle/")
        #expect(try highland.imported().bundle.text.isEmpty == false)
    }

    @Test("Every bundle in the library imports, and its payload parses")
    func wholeLibrary() throws {
        let bundles = try #require(
            HighlandCorpus.bundles,
            "Reference corpus not present on this machine."
        )
        #expect(bundles.count == 59)

        var failures: [String] = []
        var payloadNames: [String: Int] = [:]
        var generations: [HighlandBundle.Generation: Int] = [:]

        for url in bundles {
            do {
                let result = try HighlandBundle(contentsOf: url).imported()
                payloadNames[result.bundle.textFileName, default: 0] += 1
                generations[result.generation, default: 0] += 1
                #expect(result.unreadable.isEmpty, "\(url.lastPathComponent) has damaged sidecars")
                _ = ScriptParser.parse(result.bundle.text)
            } catch {
                failures.append(url.lastPathComponent)
            }
        }

        #expect(failures == HighlandCorpus.knownDamaged)
        // The split recorded in CLAUDE.md — 39 `text.fountain`, 19 `text.md` —
        // which already accounts for all 58 openable bundles.
        #expect(payloadNames == ["text.fountain": 39, "text.md": 19])
        #expect(generations == [.legacy: 21, .current: 37])
    }

    // MARK: - info.json

    @Test("Unknown info.json payloads survive, ours is added beside them")
    func infoJSONIsPreserved() throws {
        let url = try #require(HighlandCorpus.bundle(named: "Clean Break.highland"))
        let bundle = try HighlandBundle(contentsOf: url).textBundle()
        let infoData = try #require(bundle.infoData)
        let info = try #require(
            JSONSerialization.jsonObject(with: infoData) as? [String: Any]
        )

        // Highland's own namespace is carried through untouched...
        let highland = try #require(info[HighlandBundle.highlandNamespace] as? [String: Any])
        #expect(highland["templateName"] as? String == "Screenplay")
        // ...but the document is ours now.
        #expect(info["type"] as? String == TextBundle.uti)

        let ours = try #require(info[TextBundle.settingsNamespace] as? [String: Any])
        #expect(ours["importedFrom"] as? String == HighlandBundle.highlandNamespace)
        #expect(ours["importedType"] as? String == "com.quoteunquoteapps.fountain")
        // Mapped from `resources/settings.json` → `printSettings`.
        #expect(ours["printTitlePage"] as? Bool == true)
        #expect(ours["printSections"] as? Bool == true)
        #expect(ours["printSynopses"] as? Bool == false)
        #expect(ours["printInlineNotes"] as? Bool == false)
        // The document template, not `printSettings`' "Default".
        #expect(ours["template"] as? String == "Screenplay")
    }

    /// Highland writes the same flags in three places, added over successive
    /// versions. The newest wins, and a flag nobody set is left unset rather
    /// than invented — `printSections` especially, whose Highland default of
    /// off is why the Trophy Boyz sections vanish from Highland's PDFs.
    @Test("Print settings merge newest-wins, and absence stays absent")
    func settingsPrecedence() {
        let info: [String: Any] = [
            "type": "com.quoteunquoteapps.fountain",
            HighlandBundle.highlandNamespace: [
                "templateName": "Screenplay",
                "printOptions": ["printTitlePage": false, "printSynopses": true]
            ]
        ]
        let resources: [[String: Any]] = [[
            "printSettings": [
                "printTitlePage": true,
                "printSections": true,
                // The *print* template, not the document's. Always "Default".
                "templateName": "Default"
            ]
        ]]

        let merged = HighlandBundle.settings(from: info, resources: resources)
        #expect(merged["printTitlePage"] as? Bool == true)   // resources beat printOptions
        #expect(merged["printSynopses"] as? Bool == true)    // only printOptions had it
        #expect(merged["printSections"] as? Bool == true)
        #expect(merged["template"] as? String == "Screenplay")
        #expect(merged["printInlineNotes"] == nil)           // nobody set it: stays unset

        let bare = HighlandBundle.settings(from: [:], resources: [])
        #expect(bare["printTitlePage"] == nil)
        #expect(bare["version"] as? Int == 1)
    }

    // MARK: - Opaque state

    @Test("Highland’s base64 revision archive is dropped, and can be kept")
    func opaqueRevisionState() throws {
        let url = try #require(HighlandCorpus.bundle(named: "Clean Break.highland"))
        let highland = try HighlandBundle(contentsOf: url)

        let dropped = try highland.imported()
        #expect(dropped.dropped == ["revisions/current.json"])
        #expect(dropped.droppedBytes > 200_000)
        #expect(dropped.bundle.extras["revisions/current.json"] == nil)

        let kept = try highland.imported(keepingOpaqueState: true)
        #expect(kept.dropped.isEmpty)
        let raw = try #require(kept.bundle.extras["revisions/current.json"])
        #expect(raw.count == dropped.droppedBytes)
        // Verbatim, not reserialised — and this is what "opaque" means: a
        // base64 binary plist holding an NSKeyedArchiver object graph.
        let json = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(json["number"] as? Int == 0)
        let content = try #require(json["content"] as? String)
        let plist = try #require(Data(base64Encoded: content))
        #expect(plist.prefix(6) == Data("bplist".utf8))

        // `resources/revisions.json` is plain JSON, so it is never dropped.
        #expect(dropped.dropped.allSatisfy { $0 != "resources/revisions.json" })
    }

    // MARK: - Round trip

    @Test("An imported bundle round-trips through the uncompressed format")
    func roundTrip() throws {
        let url = try #require(HighlandCorpus.bundle(named: "Anal Informant - 6.1.highland"))
        let original = try HighlandBundle(contentsOf: url).textBundle()

        let reread = try TextBundle(directory: original.directoryWrapper())
        #expect(reread.text == original.text)
        #expect(reread.textFileName == original.textFileName)
        #expect(reread.infoData == original.infoData)
        #expect(reread.extras == original.extras)
        // Including the nested ones, rebuilt as folders rather than flattened.
        #expect(reread.extras["resources/shelf.json"] != nil)
        #expect(reread.extras["bin/9.txt"] != nil)
    }

    // MARK: - The case that motivates the feature

    /// Trophy Boyz writes every slugline as a section — `## 1. EXT. RAVINE -
    /// DAY` — which Highland accepts in the outline and then silently omits
    /// from the PDF. Migrating is what makes that visible, and it is the
    /// highest-value lint rule to write next.
    @Test("The Trophy Boyz episodes import as sections, not scene headings")
    func trophyBoyzSlugsAreSections() throws {
        try #require(HighlandCorpus.bundles != nil, "Reference corpus not present.")

        var perEpisode: [Int] = []
        var realSceneHeadings = 0

        for number in 1...6 {
            guard let url = HighlandCorpus.bundle(named: "Episode \(number).highland") else {
                continue
            }
            let text = try HighlandBundle(contentsOf: url).textBundle().text
            let script = ScriptParser.parse(text)
            realSceneHeadings += script.scenes.count

            let disguised = script.elements.filter {
                $0.kind == .section
                    && ScriptParser.isSceneHeading(Self.stripSectionOrdinal($0.text))
            }
            perEpisode.append(disguised.count)
            #expect(disguised.first?.depth == 2, "Episode \(number) numbers with `## `")
        }

        // Measured: 9, 5, 6, 9, 8, 5 — every slugline in all six episodes, and
        // not one real scene heading between them. Highland prints none of it.
        #expect(perEpisode == [9, 5, 6, 9, 8, 5])
        #expect(realSceneHeadings == 0)
    }

    /// `1. EXT. RAVINE - DAY` → `EXT. RAVINE - DAY`.
    static func stripSectionOrdinal(_ title: String) -> String {
        guard let dot = title.firstIndex(of: "."),
              title[title.startIndex..<dot].allSatisfy(\.isNumber),
              dot > title.startIndex else { return title }
        return String(title[title.index(after: dot)...])
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Helpers

    /// At least eight bundles, spanning both generations, both payload names
    /// and both compression methods.
    static var sample: [URL]? {
        guard let bundles = HighlandCorpus.bundles else { return nil }
        let names = [
            // Legacy layout, `text.md`, stored entries.
            "Clean Break.highland",
            "Anal Informant11.17.highland",
            "Night Vision.highland",
            "TheLastDinnerParty.highland",
            "Untitled 2.highland",
            // Legacy layout, `text.fountain`.
            "Anal Informant - MASTER.highland",
            "Anal Informant - 6.1.highland",
            // Current layout, `text.fountain`, deflated entries.
            "Episode 1.highland",
            "Episode 6.highland",
            "Rebase.highland",
            "The Quiet Night.highland",
            // Current layout, `text.md`.
            "Bret Book.highland"
        ]
        let found = names.compactMap { name in
            bundles.first { $0.lastPathComponent == name }
        }
        return found.count == names.count ? found : nil
    }

    /// Extracts one entry with `/usr/bin/unzip`, the independent implementation
    /// this reader is checked against.
    static func unzip(entry: String, from url: URL) -> Data? {
        // `unzip` treats the member name as a shell-style pattern.
        let pattern = entry.reduce(into: "") { escaped, character in
            if "[]*?\\".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, pattern]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}

private extension FileManager {
    /// Size, modification date and inode — enough to catch any write.
    func attributeKeys(for url: URL) -> String {
        let attributes = try? attributesOfItem(atPath: url.path)
        return [FileAttributeKey.size, .modificationDate, .systemFileNumber]
            .map { "\($0.rawValue)=\(String(describing: attributes?[$0]))" }
            .joined(separator: " ")
    }
}
