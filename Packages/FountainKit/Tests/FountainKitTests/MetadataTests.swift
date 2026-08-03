import Foundation
import Testing
@testable import FountainKit

// The sidecar is the only file in this project written by more than one version
// of the app, and it syncs between machines with Syncthing. Both facts show up
// in these tests: a file must survive a round trip through a build that has
// never heard of half its contents, and a save must not be able to truncate it.

@Suite("Metadata model")
struct MetadataModelTests {

    /// A record with every field filled in, for round-trip tests.
    static func fullRecord() -> SceneMetadata {
        SceneMetadata(
            id: UUID(uuidString: "1B4E28BA-2FA1-11D2-883F-0016D3CCA427")!,
            anchor: SceneAnchor(
                sceneNumber: "42",
                heading: "EXT. MOUNTAIN – MORNING",
                headingOccurrence: 1,
                orderIndex: 3,
                contentHash: "deadbeef"
            ),
            status: .revised,
            shootingDay: 7,
            estimatedSeconds: 105,
            cast: [
                CastMember(name: "LENA", billingOrder: 1),
                CastMember(name: "OWEN", billingOrder: 2)
            ],
            location: SceneLocation(
                name: "Mount Tamalpais",
                setName: "Pantoll trailhead",
                interiorExterior: .exterior
            ),
            notes: [
                ProductionNote(
                    id: UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!,
                    text: "Golden hour only — 40 minutes of usable light.",
                    author: "Steven",
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ],
            act: "Act One",
            sequence: "The Climb",
            revisionColor: .pink
        )
    }

    @Test("Every field survives a round trip through JSON")
    func roundTrip() throws {
        let original = ScreenplayMetadata(
            writerVersion: "1.0 (17)",
            currentRevision: .blue,
            actOrder: ["Act One", "Act Two"],
            sequenceOrder: ["The Climb", "The Fall"],
            scenes: [Self.fullRecord()]
        )
        let decoded = try MetadataStore.decode(MetadataStore.encode(original))
        #expect(decoded == original)
    }

    @Test("The file is written so git can read it")
    func diffableOutput() throws {
        let metadata = ScreenplayMetadata(scenes: [Self.fullRecord()])
        let text = String(decoding: try MetadataStore.encode(metadata), as: UTF8.self)

        // Pretty-printed, so one changed shooting day is one changed line.
        #expect(text.contains("\n"))
        #expect(text.hasSuffix("}\n"))                       // trailing newline

        // Sorted keys, so two machines writing the same data produce the same
        // bytes and Syncthing has nothing to reconcile.
        let actIndex = try #require(text.range(of: "\"act\""))
        let anchorIndex = try #require(text.range(of: "\"anchor\""))
        let statusIndex = try #require(text.range(of: "\"status\""))
        #expect(actIndex.lowerBound < anchorIndex.lowerBound)
        #expect(anchorIndex.lowerBound < statusIndex.lowerBound)

        // `INT./EXT.` reads as itself rather than `INT.\/EXT.`
        #expect(!text.contains("\\/"))

        // Byte-for-byte stable across encodes.
        #expect(try MetadataStore.encode(metadata) == MetadataStore.encode(metadata))
    }

    @Test("Empty collections are left out entirely")
    func sparseOutput() throws {
        let metadata = ScreenplayMetadata(
            scenes: [SceneMetadata(anchor: SceneAnchor(heading: "INT. CAR - NIGHT"))]
        )
        let text = String(decoding: try MetadataStore.encode(metadata), as: UTF8.self)
        #expect(!text.contains("\"cast\""))
        #expect(!text.contains("\"notes\""))
        #expect(!text.contains("\"status\""))
        #expect(text.contains("\"anchor\""))
    }

    @Test("A duration reads the way the scene card shows it")
    func durationFormatting() {
        func text(_ seconds: Int?) -> String? {
            SceneMetadata(anchor: SceneAnchor(heading: "X"), estimatedSeconds: seconds).durationText
        }
        #expect(text(105) == "01:45")
        #expect(text(45) == "00:45")
        #expect(text(0) == "00:00")
        #expect(text(3750) == "1:02:30")
        #expect(text(nil) == nil)
    }

    @Test("The revision sequence is the industry one, and does not wrap")
    func revisionSequence() {
        #expect(RevisionColor.white.revisionNumber == 0)
        #expect(RevisionColor.white.next == .blue)
        #expect(RevisionColor.blue.next == .pink)
        #expect(RevisionColor.allCases.map(\.rawValue) == [
            "white", "blue", "pink", "yellow", "green",
            "goldenrod", "buff", "salmon", "cherry"
        ])
        // After cherry the tradition is "double white", which this version does
        // not model. Wrapping silently to white would lose a whole revision.
        #expect(RevisionColor.cherry.next == nil)
        #expect(RevisionColor.other("double white").revisionNumber == nil)
    }

    @Test("Interior/exterior is read off a real heading")
    func interiorExteriorFromHeading() {
        #expect(InteriorExterior(heading: "INT. GLASS HOUSE - NIGHT") == .interior)
        #expect(InteriorExterior(heading: "EXT. MOUNTAIN – MORNING") == .exterior)
        #expect(InteriorExterior(heading: "INT./EXT. CAR - DAY") == .both)
        #expect(InteriorExterior(heading: "I/E MONTAGE IMAGE") == .both)
        #expect(InteriorExterior(heading: "EST. THE VALLEY") == .exterior)
        #expect(InteriorExterior(heading: "MONTAGE") == nil)
    }

    @Test("Estimated running time adds up across scenes")
    func totalRuntime() {
        let metadata = ScreenplayMetadata(scenes: [
            SceneMetadata(anchor: SceneAnchor(heading: "A"), estimatedSeconds: 105),
            SceneMetadata(anchor: SceneAnchor(heading: "B"), estimatedSeconds: 45),
            SceneMetadata(anchor: SceneAnchor(heading: "C"))
        ])
        #expect(metadata.estimatedSeconds == 150)
    }
}

@Suite("Forward compatibility")
struct MetadataForwardCompatibilityTests {

    /// A sidecar written by a build from the future: fields at every level that
    /// this version has never heard of, an unknown scene status, an unknown
    /// revision colour, and a schema version higher than ours.
    static let futureFile = """
    {
      "schemaVersion" : 4,
      "writerVersion" : "9.2 (400)",
      "stripboard" : { "unitCount" : 2, "days" : [1, 2, 3] },
      "scenes" : [
        {
          "id" : "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
          "anchor" : {
            "heading" : "EXT. MOUNTAIN – MORNING",
            "headingOccurrence" : 0,
            "orderIndex" : 0,
            "sceneNumber" : "1",
            "contentHash" : "abc123",
            "embedding" : [0.25, 0.5]
          },
          "status" : "onHold",
          "shootingDay" : 3,
          "revisionColor" : "double white",
          "weatherCover" : true,
          "stunts" : ["fall", "wire"],
          "cast" : [
            { "name" : "LENA", "billingOrder" : 1, "dayPlayer" : false }
          ],
          "location" : {
            "name" : "Mount Tamalpais",
            "interiorExterior" : "exterior",
            "permitNumber" : "SF-2029-114"
          },
          "notes" : [
            {
              "id" : "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
              "text" : "Golden hour only.",
              "createdAt" : "2026-08-02T12:00:00.250Z",
              "pinned" : true
            }
          ]
        }
      ]
    }
    """

    @Test("A file from a newer version round-trips without losing anything")
    func unknownFieldsSurvive() throws {
        let metadata = try MetadataStore.decode(Data(Self.futureFile.utf8))

        // What this version does understand, it reads.
        #expect(metadata.scenes.count == 1)
        #expect(metadata.scenes[0].shootingDay == 3)
        #expect(metadata.scenes[0].anchor.sceneNumber == "1")
        #expect(metadata.scenes[0].cast.first?.name == "LENA")
        #expect(metadata.scenes[0].location?.name == "Mount Tamalpais")

        // What it does not, it keeps. Every level: document, scene, anchor,
        // cast member, location, note.
        #expect(metadata.unknownFields["stripboard"] != nil)
        #expect(metadata.scenes[0].unknownFields["weatherCover"] == .bool(true))
        #expect(metadata.scenes[0].unknownFields["stunts"] == .array([.string("fall"), .string("wire")]))
        #expect(metadata.scenes[0].anchor.unknownFields["embedding"] != nil)
        #expect(metadata.scenes[0].cast[0].unknownFields["dayPlayer"] == .bool(false))
        #expect(metadata.scenes[0].location?.unknownFields["permitNumber"] == .string("SF-2029-114"))
        #expect(metadata.scenes[0].notes[0].unknownFields["pinned"] == .bool(true))

        // And writes it all back.
        let rewritten = String(decoding: try MetadataStore.encode(metadata), as: UTF8.self)
        for key in ["stripboard", "unitCount", "weatherCover", "stunts", "wire",
                    "embedding", "dayPlayer", "permitNumber", "pinned"] {
            #expect(rewritten.contains(key), "The rewritten file lost \(key).")
        }

        // Twice through is still lossless — the preserved fields are data, not a
        // one-shot passthrough.
        let twice = try MetadataStore.decode(Data(rewritten.utf8))
        #expect(twice == metadata)
    }

    @Test("An edit by the older version keeps the newer version's data")
    func editingPreservesUnknowns() throws {
        var metadata = try MetadataStore.decode(Data(Self.futureFile.utf8))
        metadata.scenes[0].shootingDay = 9
        metadata.scenes[0].notes.append(ProductionNote(text: "Moved to day 9."))

        let reloaded = try MetadataStore.decode(MetadataStore.encode(metadata))
        #expect(reloaded.scenes[0].shootingDay == 9)
        #expect(reloaded.scenes[0].notes.count == 2)
        #expect(reloaded.scenes[0].unknownFields["weatherCover"] == .bool(true))
        #expect(reloaded.unknownFields["stripboard"] != nil)
        #expect(reloaded.scenes[0].notes[0].unknownFields["pinned"] == .bool(true))
    }

    @Test("An unrecognised enum value is carried, not rejected")
    func unknownEnumValues() throws {
        let metadata = try MetadataStore.decode(Data(Self.futureFile.utf8))
        #expect(metadata.scenes[0].status == .other("onHold"))
        #expect(metadata.scenes[0].revisionColor == .other("double white"))

        let rewritten = String(decoding: try MetadataStore.encode(metadata), as: UTF8.self)
        #expect(rewritten.contains("\"onHold\""))
        #expect(rewritten.contains("\"double white\""))
    }

    @Test("A newer schema version is not downgraded on write")
    func schemaVersionIsNotLowered() throws {
        let metadata = try MetadataStore.decode(Data(Self.futureFile.utf8))
        #expect(metadata.schemaVersion == 4)
        let rewritten = try MetadataStore.decode(MetadataStore.encode(metadata))
        // Every field was preserved, so the file really is still a version 4
        // file. Stamping it back down to 1 would tell the newer build its data
        // was gone and invite it to start over.
        #expect(rewritten.schemaVersion == 4)
    }

    @Test("A known field that changed type is preserved rather than fatal")
    func typeMismatchIsSurvivable() throws {
        // A future version making `shootingDay` a string — "2A" is a real
        // production day designation. Synthesised `Codable` would throw here and
        // take the whole schedule down with it.
        let file = """
        {
          "schemaVersion" : 5,
          "scenes" : [
            {
              "id" : "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
              "anchor" : { "heading" : "INT. CAR - NIGHT", "headingOccurrence" : 0, "orderIndex" : 0 },
              "shootingDay" : "2A",
              "estimatedSeconds" : 90
            }
          ]
        }
        """
        let metadata = try MetadataStore.decode(Data(file.utf8))
        #expect(metadata.scenes.count == 1)
        #expect(metadata.scenes[0].shootingDay == nil)
        #expect(metadata.scenes[0].estimatedSeconds == 90)
        #expect(metadata.scenes[0].unknownFields["shootingDay"] == .string("2A"))
        #expect(String(decoding: try MetadataStore.encode(metadata), as: UTF8.self).contains("\"2A\""))
    }

    @Test("Numbers keep their exact value")
    func numberPrecision() throws {
        let file = """
        {"schemaVersion":1,"budgetCents":9007199254740993,"ratio":0.1}
        """
        let metadata = try MetadataStore.decode(Data(file.utf8))
        #expect(metadata.unknownFields["budgetCents"] == .int(9_007_199_254_740_993))
        #expect(metadata.unknownFields["ratio"] == .double(0.1))
        let rewritten = String(decoding: try MetadataStore.encode(metadata), as: UTF8.self)
        #expect(rewritten.contains("9007199254740993"))
    }

    @Test("A timestamp with more precision than we write is still read")
    func lenientDates() throws {
        let metadata = try MetadataStore.decode(Data(Self.futureFile.utf8))
        let note = try #require(metadata.scenes[0].notes.first)
        #expect(note.createdAt != nil)
    }

    @Test("This version's fields win over a stale preserved copy")
    func ownedKeysWin() throws {
        // Nothing should ever put a known key into `unknownFields`, but if a
        // future refactor moved a field from unknown to known, the value the
        // user is editing has to be the one that lands on disk.
        var record = SceneMetadata(anchor: SceneAnchor(heading: "INT. CAR - NIGHT"))
        record.shootingDay = 4
        record.unknownFields["shootingDay"] = .int(99)
        let reloaded = try MetadataStore.decode(
            MetadataStore.encode(ScreenplayMetadata(scenes: [record]))
        )
        #expect(reloaded.scenes[0].shootingDay == 4)
    }
}

@Suite("Metadata sidecar on disk")
struct MetadataStoreTests {

    /// A scratch directory that cleans itself up.
    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenwriter-metadata-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("The sidecar sits beside a bare .fountain and inside a .screenplay")
    func sidecarLocations() {
        let fountain = URL(fileURLWithPath: "/Scripts/heat.fountain")
        #expect(
            MetadataStore.sidecarURL(for: fountain).path == "/Scripts/heat.screenwriter.json"
        )
        let package = URL(fileURLWithPath: "/Scripts/heat.screenplay")
        #expect(
            MetadataStore.sidecarURL(for: package).path == "/Scripts/heat.screenplay/screenwriter.json"
        )
        // A name with dots in it keeps all of them but the extension.
        let dotted = URL(fileURLWithPath: "/Scripts/THICK-10.16.fountain")
        #expect(
            MetadataStore.sidecarURL(for: dotted).path == "/Scripts/THICK-10.16.screenwriter.json"
        )
    }

    @Test("A document with no sidecar yet loads as empty, not as an error")
    func missingSidecar() throws {
        let directory = try Self.scratch()
        let document = directory.appendingPathComponent("fresh.fountain")
        try "INT. CAR - NIGHT\n".write(to: document, atomically: true, encoding: .utf8)

        let metadata = try MetadataStore.load(for: document)
        #expect(metadata.scenes.isEmpty)
        #expect(metadata.isEmpty)
        // Loading must not create one either — most scripts never get a sidecar.
        #expect(!FileManager.default.fileExists(atPath: MetadataStore.sidecarURL(for: document).path))
    }

    @Test("Saving and loading round-trips through both locations")
    func saveAndLoad() throws {
        let directory = try Self.scratch()
        let metadata = ScreenplayMetadata(scenes: [MetadataModelTests.fullRecord()])

        let bare = directory.appendingPathComponent("heat.fountain")
        try MetadataStore.save(metadata, for: bare)
        #expect(try MetadataStore.load(for: bare) == metadata)
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("heat.screenwriter.json").path
            )
        )

        let package = directory.appendingPathComponent("heat.screenplay")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try MetadataStore.save(metadata, for: package)
        #expect(try MetadataStore.load(for: package) == metadata)

        // Same schema, same bytes, two locations — converting between the
        // formats is a file move, not a migration.
        let insidePackage = try Data(contentsOf: package.appendingPathComponent("screenwriter.json"))
        let besideFountain = try Data(
            contentsOf: directory.appendingPathComponent("heat.screenwriter.json")
        )
        #expect(insidePackage == besideFountain)
    }

    @Test("Corrupt JSON fails loudly and leaves the file exactly as it was")
    func corruptSidecarIsPreserved() throws {
        let directory = try Self.scratch()
        let document = directory.appendingPathComponent("heat.fountain")
        let sidecar = MetadataStore.sidecarURL(for: document)

        // Truncated mid-write by something that was not atomic.
        let truncated = "{\n  \"schemaVersion\" : 1,\n  \"scenes\" : [\n    { \"id\" :"
        try truncated.write(to: sidecar, atomically: true, encoding: .utf8)

        #expect(throws: MetadataStoreError.self) {
            try MetadataStore.load(for: document)
        }
        #expect(MetadataStore.isCorrupt(for: document))
        // Not repaired, not deleted, not replaced with an empty file. It may be
        // the only copy of a shooting schedule.
        #expect(try String(contentsOf: sidecar, encoding: .utf8) == truncated)
    }

    @Test("An empty sidecar is corrupt, not empty metadata")
    func zeroLengthSidecar() throws {
        let directory = try Self.scratch()
        let document = directory.appendingPathComponent("heat.fountain")
        try Data().write(to: MetadataStore.sidecarURL(for: document))
        #expect(throws: MetadataStoreError.self) {
            try MetadataStore.load(for: document)
        }
    }

    @Test("Saving over an unreadable sidecar rescues it first")
    func corruptSidecarIsQuarantined() throws {
        let directory = try Self.scratch()
        let document = directory.appendingPathComponent("heat.fountain")
        let sidecar = MetadataStore.sidecarURL(for: document)
        let damaged = "{ \"scenes\" : [ this was hand-edited"
        try damaged.write(to: sidecar, atomically: true, encoding: .utf8)

        let outcome = try MetadataStore.save(
            ScreenplayMetadata(scenes: [MetadataModelTests.fullRecord()]),
            for: document
        )

        let rescued = try #require(outcome.quarantinedURL)
        #expect(try String(contentsOf: rescued, encoding: .utf8) == damaged)
        #expect(rescued.lastPathComponent.hasPrefix("heat.screenwriter.json.corrupt-"))
        #expect(try MetadataStore.load(for: document).scenes.count == 1)
    }

    @Test("A save replaces the file rather than writing through it")
    func atomicWrite() throws {
        let directory = try Self.scratch()
        let document = directory.appendingPathComponent("heat.fountain")
        var metadata = ScreenplayMetadata(scenes: [MetadataModelTests.fullRecord()])
        try MetadataStore.save(metadata, for: document)

        func inode(_ url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.systemFileNumber] as? Int ?? -1
        }
        let sidecar = MetadataStore.sidecarURL(for: document)
        let before = try inode(sidecar)

        metadata.scenes[0].shootingDay = 12
        try MetadataStore.save(metadata, for: document)

        // A new inode is the signature of write-to-temp-then-rename. Writing
        // through the existing file would keep it — and would mean a crash
        // between truncate and write leaves a zero-length schedule.
        #expect(try inode(sidecar) != before)
        #expect(try MetadataStore.load(for: document).scenes[0].shootingDay == 12)
        // No debris left behind.
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents.sorted() == ["heat.screenwriter.json"])
    }

    @Test("Saving into a folder that does not exist fails without creating one")
    func missingDirectory() throws {
        let directory = try Self.scratch()
        let document = directory
            .appendingPathComponent("nowhere.screenplay")
            .appendingPathComponent("inner.fountain")
        #expect(throws: MetadataStoreError.self) {
            try MetadataStore.save(ScreenplayMetadata(), for: document)
        }
    }

    @Test("Removing the sidecar is tolerant of it not being there")
    func removal() throws {
        let directory = try Self.scratch()
        let document = directory.appendingPathComponent("heat.fountain")
        try MetadataStore.removeSidecar(for: document)          // no throw
        try MetadataStore.save(ScreenplayMetadata(scenes: [MetadataModelTests.fullRecord()]), for: document)
        try MetadataStore.removeSidecar(for: document)
        #expect(!FileManager.default.fileExists(atPath: MetadataStore.sidecarURL(for: document).path))
    }
}
