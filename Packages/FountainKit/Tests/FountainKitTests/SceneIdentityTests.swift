import Foundation
import Testing
@testable import FountainKit

// Metadata is keyed to scenes, and scenes get reordered, retyped, split, merged
// and deleted. The failure these tests exist to prevent is not losing a link —
// that is visible, reported, and recoverable. It is a shooting day silently
// moving to the wrong scene, which nobody notices until a crew is in the wrong
// place. So every case here asserts two things: what matched, and what did *not*
// mis-match. The second assertion is the one that matters.

/// Builds a script from `(heading, body)` pairs. The body doubles as the scene's
/// identity in the assertions below — a record's `shootingDay` is the ordinal of
/// the scene it was created for, so "which record ended up here" is one lookup.
func buildScript(_ scenes: [(String, String)]) -> ParsedScript {
    ScriptParser.parse(scenes.map { "\($0.0)\n\n\($0.1)\n\n" }.joined())
}

/// One record per scene, with `shootingDay` set to the scene's zero-based
/// ordinal so any later mis-attachment is legible at a glance.
func buildMetadata(for script: ParsedScript, contentHashes: Bool = true) -> ScreenplayMetadata {
    var metadata = ScreenplayMetadata()
    for (ordinal, anchor) in SceneIdentity.anchors(for: script).enumerated() {
        var anchor = anchor
        if !contentHashes { anchor.contentHash = nil }
        metadata.scenes.append(SceneMetadata(anchor: anchor, shootingDay: ordinal))
    }
    return metadata
}

/// One-based scene index → the shooting day of the record that claimed it.
func attachments(
    _ resolution: MetadataResolution,
    _ metadata: ScreenplayMetadata
) -> [Int: Int] {
    var result: [Int: Int] = [:]
    for match in resolution.matches {
        result[match.sceneIndex] = metadata.record(id: match.recordID)?.shootingDay
    }
    return result.compactMapValues { $0 }
}

/// One-based scene index → the tier it matched at.
func tiers(_ resolution: MetadataResolution) -> [Int: MatchTier] {
    Dictionary(resolution.matches.map { ($0.sceneIndex, $0.tier) }, uniquingKeysWith: { first, _ in first })
}

@Suite("Scene identity: exact tiers")
struct SceneIdentityExactTests {

    @Test("A scene number survives being reordered and retitled at the same time")
    func sceneNumbersAreTheStrongestSignal() {
        // The corpus leans on this hard: `anal-informant.fountain` numbers all
        // 95 of its scenes.
        let original = buildScript([
            ("EXT. MOUNTAIN – MORNING #1#", "High on a peak."),
            ("INT. GLASS HOUSE - NIGHT #2#", "Rain needles the windows."),
            ("INT. SERVER ROOM - CONTINUOUS #3#", "Fans spin up.")
        ])
        let metadata = buildMetadata(for: original)

        // Reordered *and* retitled beyond recognition, which defeats every other
        // signal there is.
        let edited = buildScript([
            ("INT. SERVER ROOM - CONTINUOUS #3#", "Fans spin up."),
            ("EXT. A COMPLETELY DIFFERENT PLACE - DUSK #1#", "High on a peak."),
            ("INT. GLASS HOUSE - NIGHT #2#", "Rain needles the windows.")
        ])
        let resolution = SceneIdentityResolver.resolve(metadata, against: edited)

        #expect(attachments(resolution, metadata) == [1: 2, 2: 0, 3: 1])
        #expect(resolution.counts == [.sceneNumber: 3])
        #expect(resolution.orphanedRecordIDs.isEmpty)
        #expect(!resolution.needsReview)
    }

    @Test("A scene number appearing twice is refused, not guessed")
    func duplicateSceneNumbersFallThrough() {
        // A copy-paste leaves two scenes numbered 12. Picking one of them is a
        // coin flip, and this resolver does not flip coins.
        let original = buildScript([
            ("INT. KITCHEN - DAY #12#", "Lena burns the toast."),
            ("EXT. DRIVEWAY - DAY #13#", "Owen waits in the car.")
        ])
        let metadata = buildMetadata(for: original)

        let edited = buildScript([
            ("INT. KITCHEN - DAY #12#", "Lena burns the toast."),
            ("EXT. DRIVEWAY - DAY #12#", "Owen waits in the car.")
        ])
        let resolution = SceneIdentityResolver.resolve(metadata, against: edited)

        // Both still land correctly — but by heading, not by number, and the
        // result says so. A UI that trusted the tier would be right to.
        #expect(attachments(resolution, metadata) == [1: 0, 2: 1])
        #expect(tiers(resolution) == [1: .heading, 2: .heading])
    }

    @Test("Reordering scenes moves their metadata with them")
    func reorder() {
        let original = buildScript([
            ("INT. KITCHEN - DAY", "Lena burns the toast."),
            ("EXT. DRIVEWAY - DAY", "Owen waits in the car."),
            ("INT. SERVER ROOM - NIGHT", "Fans spin up."),
            ("EXT. RAVINE - DUSK", "The car is at the bottom.")
        ])
        let metadata = buildMetadata(for: original)

        let edited = buildScript([
            ("EXT. RAVINE - DUSK", "The car is at the bottom."),
            ("INT. KITCHEN - DAY", "Lena burns the toast."),
            ("INT. SERVER ROOM - NIGHT", "Fans spin up."),
            ("EXT. DRIVEWAY - DAY", "Owen waits in the car.")
        ])
        let resolution = SceneIdentityResolver.resolve(metadata, against: edited)

        #expect(attachments(resolution, metadata) == [1: 3, 2: 0, 3: 2, 4: 1])
        #expect(resolution.counts == [.heading: 4])
    }

    @Test("An en dash and a hyphen are the same heading")
    func dashNormalisation() {
        // `EXT. MOUNTAIN – MORNING` is verbatim from the corpus. Typing the
        // hyphen version later must not break the link.
        let original = buildScript([("EXT.  MOUNTAIN – MORNING", "High on a peak.")])
        let metadata = buildMetadata(for: original)
        let edited = buildScript([("ext. mountain - morning", "High on a peak.")])

        let resolution = SceneIdentityResolver.resolve(metadata, against: edited)
        #expect(tiers(resolution) == [1: .heading])
        #expect(SceneIdentity.normalize(heading: "EXT.  MOUNTAIN – MORNING")
            == "ext. mountain - morning")
    }
}

@Suite("Scene identity: edits that break the link")
struct SceneIdentityEditTests {

    static let original: [(String, String)] = [
        ("INT. KITCHEN - DAY", "Lena burns the toast."),
        ("EXT. DRIVEWAY - DAY", "Owen waits in the car."),
        ("INT. SERVER ROOM - NIGHT", "Fans spin up."),
        ("EXT. RAVINE - DUSK", "The car is at the bottom.")
    ]

    @Test("A slightly renamed heading matches loosely, and admits it")
    func slightRename() {
        let original = buildScript(Self.original)
        let metadata = buildMetadata(for: original)

        var edited = Self.original
        edited[2].0 = "INT. SERVER ROOM - ANNEX - NIGHT"
        let resolution = SceneIdentityResolver.resolve(metadata, against: buildScript(edited))

        #expect(attachments(resolution, metadata) == [1: 0, 2: 1, 3: 2, 4: 3])
        #expect(tiers(resolution)[3] == .fuzzy)
        // The UI needs to show a loose match differently from an exact one, so
        // the score comes back with it.
        let loose = resolution.matches.first { $0.tier == .fuzzy }
        #expect((loose?.similarity ?? 0) > HeadingSimilarity.matchThreshold)
        #expect(resolution.needsReview)
    }

    @Test("A heading renamed beyond recognition orphans instead of guessing")
    func renameBeyondRecognition() {
        let original = buildScript(Self.original)
        let metadata = buildMetadata(for: original)

        var edited = Self.original
        edited[2].0 = "EXT. A FIELD IN NEBRASKA - DAWN"
        let resolution = SceneIdentityResolver.resolve(metadata, against: buildScript(edited))

        // The unrecognisable scene keeps nothing, and — the assertion that
        // matters — nothing else moved onto it either.
        #expect(attachments(resolution, metadata) == [1: 0, 2: 1, 4: 3])
        #expect(resolution.unmatchedSceneIndices == [3])
        #expect(resolution.orphanedRecordIDs.count == 1)
        #expect(resolution.tier(for: resolution.orphanedRecordIDs[0]) == .orphan)
        // The record is still there. Losing the link is not losing the data.
        #expect(metadata.scenes.count == 4)
    }

    @Test("Deleting a scene orphans exactly one record and shifts none")
    func deletion() {
        let original = buildScript(Self.original)
        let metadata = buildMetadata(for: original)

        var edited = Self.original
        edited.remove(at: 1)
        let resolution = SceneIdentityResolver.resolve(metadata, against: buildScript(edited))

        #expect(attachments(resolution, metadata) == [1: 0, 2: 2, 3: 3])
        #expect(resolution.orphanedRecordIDs.count == 1)
        #expect(resolution.unmatchedSceneIndices.isEmpty)
    }

    @Test("An inserted scene takes nothing from its neighbours")
    func insertion() {
        let original = buildScript(Self.original)
        let metadata = buildMetadata(for: original)

        var edited = Self.original
        edited.insert(("INT. HALLWAY - DAY", "She hesitates at the door."), at: 2)
        let resolution = SceneIdentityResolver.resolve(metadata, against: buildScript(edited))

        #expect(attachments(resolution, metadata) == [1: 0, 2: 1, 4: 2, 5: 3])
        #expect(resolution.unmatchedSceneIndices == [3])
        #expect(resolution.orphanedRecordIDs.isEmpty)
    }

    @Test("Splitting a scene keeps the metadata on the half that kept the heading")
    func split() {
        let original = buildScript(Self.original)
        let metadata = buildMetadata(for: original)

        // The writer cuts the server room in half and gives the second part its
        // own slugline — the commonest structural edit there is.
        var edited = Self.original
        edited[2].1 = "Fans spin up."
        edited.insert(("INT. SERVER ROOM - RACK 4 - CONTINUOUS", "A drive light blinks red."), at: 3)
        let resolution = SceneIdentityResolver.resolve(metadata, against: buildScript(edited))

        #expect(attachments(resolution, metadata) == [1: 0, 2: 1, 3: 2, 5: 3])
        #expect(resolution.unmatchedSceneIndices == [4])
        #expect(resolution.orphanedRecordIDs.isEmpty)
        // The new half is a new scene, so a UI can offer to copy the cast across
        // — but nothing pretended it already had.
        #expect(tiers(resolution)[4] == nil)
    }

    @Test("Merging two scenes orphans the record whose heading is gone")
    func merge() {
        let original = buildScript(Self.original)
        let metadata = buildMetadata(for: original)

        // The driveway heading is deleted and its action folded into the kitchen.
        var edited = Self.original
        edited[0].1 = "Lena burns the toast. Owen waits in the car."
        edited.remove(at: 1)
        let resolution = SceneIdentityResolver.resolve(metadata, against: buildScript(edited))

        #expect(attachments(resolution, metadata) == [1: 0, 2: 2, 3: 3])
        #expect(resolution.orphanedRecordIDs.count == 1)
    }

    @Test("Renaming and reordering at once resolves what it can and refuses the rest")
    func renameAndReorderTogether() {
        // The worst realistic case: every heading edited *and* the order
        // changed, with no scene numbers to fall back on. There is no way to
        // recover all three links, and a matcher that tried would cross itself.
        let original = buildScript([
            ("INT. KITCHEN - DAY", "Lena burns the toast."),
            ("EXT. RAVINE - DAWN", "The car is at the bottom."),
            ("INT. SERVER ROOM - NIGHT", "Fans spin up.")
        ])
        let metadata = buildMetadata(for: original)

        let edited = buildScript([
            ("INT. SERVER ROOM - ANNEX - NIGHT", "Fans spin up."),
            ("INT. LENA'S KITCHEN - DAY", "Lena burns the toast."),
            ("EXT. RAVINE ROAD - DAWN", "The car is at the bottom.")
        ])
        let resolution = SceneIdentityResolver.resolve(metadata, against: edited)

        // Two links kept, one given up — and not one record on a scene that is
        // not its own.
        for (sceneIndex, day) in attachments(resolution, metadata) {
            #expect(
                [1: 2, 2: 0, 3: 1][sceneIndex] == day,
                "Record \(day) attached to scene \(sceneIndex), which is not where it came from."
            )
        }
        #expect(resolution.matches.count == 2)
        #expect(resolution.matches.allSatisfy { $0.tier == .fuzzy })
        #expect(resolution.orphanedRecordIDs.count == 1)
        #expect(resolution.needsReview)
    }

    @Test("Moving a block does not drag metadata across the scenes it passed")
    func blockMove() {
        // The regression this whole ordering constraint exists for: a loose
        // match must never reach across a confident one, or a whole run of
        // metadata slides by one and every shooting day after it is wrong.
        let original = buildScript([
            ("INT. A - DAY", "One."),
            ("INT. B - DAY", "Two."),
            ("INT. C - DAY", "Three."),
            ("INT. D - DAY", "Four."),
            ("INT. E - DAY", "Five.")
        ])
        let metadata = buildMetadata(for: original)

        let edited = buildScript([
            ("INT. D - DAY", "Four."),
            ("INT. E - DAY", "Five."),
            ("INT. A - DAY", "One."),
            ("INT. B - DAY", "Two."),
            ("INT. C - DAY", "Three.")
        ])
        let resolution = SceneIdentityResolver.resolve(metadata, against: edited)

        #expect(attachments(resolution, metadata) == [1: 3, 2: 4, 3: 0, 4: 1, 5: 2])
        #expect(resolution.counts == [.heading: 5])
    }
}

@Suite("Scene identity: duplicate headings")
struct SceneIdentityDuplicateTests {

    static let duplicated: [(String, String)] = [
        ("INT. CAR - NIGHT", "Owen drives. Nobody speaks."),
        ("EXT. GAS STATION - NIGHT", "Fluorescent light on wet tarmac."),
        ("INT. CAR - NIGHT", "Lena takes the wheel."),
        ("EXT. RAVINE - DAWN", "The car is at the bottom.")
    ]

    @Test("A heading used twice is told apart by what is under it")
    func duplicateHeadingsResolveByContent() {
        let original = buildScript(Self.duplicated)
        let metadata = buildMetadata(for: original)

        // The two `INT. CAR - NIGHT` scenes swap places. Their ordinals are now
        // exactly wrong, and only the bodies say so.
        var edited = Self.duplicated
        edited.swapAt(0, 2)
        let resolution = SceneIdentityResolver.resolve(metadata, against: buildScript(edited))

        #expect(attachments(resolution, metadata) == [1: 2, 2: 1, 3: 0, 4: 3])
        #expect(resolution.counts == [.heading: 4])
    }

    @Test("Two adjacent scenes with the same heading swap without shuffling their days")
    func adjacentIdenticalHeadingsSwap() {
        let original = buildScript([
            ("INT. CAR - NIGHT", "Owen drives."),
            ("INT. CAR - NIGHT", "Lena takes the wheel."),
            ("EXT. RAVINE - DAWN", "The car is at the bottom.")
        ])
        let metadata = buildMetadata(for: original)

        let edited = buildScript([
            ("INT. CAR - NIGHT", "Lena takes the wheel."),
            ("INT. CAR - NIGHT", "Owen drives."),
            ("EXT. RAVINE - DAWN", "The car is at the bottom.")
        ])
        let resolution = SceneIdentityResolver.resolve(metadata, against: edited)

        #expect(attachments(resolution, metadata) == [1: 1, 2: 0, 3: 2])
        #expect(resolution.counts == [.heading: 3])
    }

    @Test("Two scenes identical in every respect are matched one to one")
    func indistinguishableScenes() {
        // Same heading, same body. There is no signal left that could tell these
        // apart, and no answer that is more right than the other. What the
        // resolver must still guarantee is that each record lands on exactly one
        // scene and no scene collects two.
        let source: [(String, String)] = [
            ("INT. CAR - NIGHT", "Rain on the windscreen."),
            ("INT. CAR - NIGHT", "Rain on the windscreen."),
            ("EXT. RAVINE - DAWN", "The car is at the bottom.")
        ]
        let metadata = buildMetadata(for: buildScript(source))
        let resolution = SceneIdentityResolver.resolve(metadata, against: buildScript(source))

        #expect(resolution.matches.count == 3)
        #expect(Set(resolution.matches.map(\.sceneIndex)).count == 3)
        #expect(Set(resolution.matches.map(\.recordID)).count == 3)
        #expect(resolution.orphanedRecordIDs.isEmpty)
    }

    @Test("Deleting one of three identical headings does not slide the other two")
    func deletionAmongIdenticalHeadings() {
        // The textbook way to corrupt a schedule: three scenes share a heading,
        // the first is cut, and ordinal matching quietly hands every record to
        // its neighbour. The content fingerprint is what stops it.
        let original = buildScript([
            ("INT. FACILITY B-7 - LAB 7 - CONTINUOUS", "Franko checks the seal."),
            ("INT. FACILITY B-7 - LAB 7 - CONTINUOUS", "Judd reads the gauge."),
            ("INT. FACILITY B-7 - LAB 7 - CONTINUOUS", "Bobby drops the tray.")
        ])
        let metadata = buildMetadata(for: original)

        let edited = buildScript([
            ("INT. FACILITY B-7 - LAB 7 - CONTINUOUS", "Judd reads the gauge."),
            ("INT. FACILITY B-7 - LAB 7 - CONTINUOUS", "Bobby drops the tray.")
        ])
        let resolution = SceneIdentityResolver.resolve(metadata, against: edited)

        #expect(attachments(resolution, metadata) == [1: 1, 2: 2])
        #expect(resolution.orphanedRecordIDs.count == 1)
    }

    @Test("With no fingerprints to go on, the same deletion refuses every match")
    func deletionAmongIdenticalHeadingsWithoutHashes() {
        // A sidecar written by hand, or by a version before fingerprints. Three
        // identical headings, two left, and nothing that says which one went.
        // Every answer is a guess, so there is no answer.
        let original = buildScript([
            ("INT. FACILITY B-7 - LAB 7 - CONTINUOUS", "Franko checks the seal."),
            ("INT. FACILITY B-7 - LAB 7 - CONTINUOUS", "Judd reads the gauge."),
            ("INT. FACILITY B-7 - LAB 7 - CONTINUOUS", "Bobby drops the tray.")
        ])
        let metadata = buildMetadata(for: original, contentHashes: false)

        let edited = buildScript([
            ("INT. FACILITY B-7 - LAB 7 - CONTINUOUS", "Judd reads the gauge."),
            ("INT. FACILITY B-7 - LAB 7 - CONTINUOUS", "Bobby drops the tray.")
        ])
        let resolution = SceneIdentityResolver.resolve(metadata, against: edited)

        #expect(resolution.matches.isEmpty)
        #expect(resolution.orphanedRecordIDs.count == 3)
        #expect(resolution.unmatchedSceneIndices == [1, 2])
    }

    @Test("A newly duplicated heading claims nothing on its own")
    func duplicatingAScene() {
        // The user copies a scene. Two identical scenes now answer to one
        // record, and neither has a better claim than the other.
        let original = buildScript([
            ("INT. KITCHEN - DAY", "Lena burns the toast."),
            ("EXT. RAVINE - DAWN", "The car is at the bottom.")
        ])
        let metadata = buildMetadata(for: original)

        let edited = buildScript([
            ("INT. KITCHEN - DAY", "Lena burns the toast."),
            ("INT. KITCHEN - DAY", "Lena burns the toast."),
            ("EXT. RAVINE - DAWN", "The car is at the bottom.")
        ])
        let resolution = SceneIdentityResolver.resolve(metadata, against: edited)

        #expect(attachments(resolution, metadata)[3] == 1)
        #expect(resolution.orphanedRecordIDs.count == 1)
        #expect(resolution.unmatchedSceneIndices == [1, 2])
    }
}

@Suite("Scene identity: what happens to what did not match")
struct SceneIdentityRetentionTests {

    @Test("Orphans are kept until something explicitly removes them")
    func orphansSurviveResolutionAndSaving() throws {
        let original = buildScript([
            ("INT. KITCHEN - DAY", "Lena burns the toast."),
            ("EXT. RAVINE - DAWN", "The car is at the bottom.")
        ])
        var metadata = buildMetadata(for: original)
        metadata.scenes[1].notes = [ProductionNote(text: "Permit expires the 14th.")]

        let edited = buildScript([("INT. KITCHEN - DAY", "Lena burns the toast.")])
        let resolution = SceneIdentityResolver.resolve(metadata, against: edited)
        #expect(resolution.orphanedRecordIDs.count == 1)

        // Resolving changes nothing on disk, and neither does re-anchoring.
        metadata.reanchor(to: edited, using: resolution)
        #expect(metadata.scenes.count == 2)
        let orphan = try #require(metadata.record(id: resolution.orphanedRecordIDs[0]))
        #expect(orphan.notes.first?.text == "Permit expires the 14th.")
        // Its old anchor is untouched — that heading is the only evidence of
        // where it came from, and it is what a re-link dialog has to show.
        #expect(orphan.anchor.heading == "EXT. RAVINE - DAWN")

        // A round trip through disk keeps it too.
        let reloaded = try MetadataStore.decode(MetadataStore.encode(metadata))
        #expect(reloaded.scenes.count == 2)

        // And only an explicit call drops it.
        let removed = metadata.removeOrphans(resolution)
        #expect(removed.count == 1)
        #expect(metadata.scenes.count == 1)
    }

    @Test("Re-anchoring describes the script as it is now")
    func reanchoring() throws {
        let original = buildScript([
            ("INT. KITCHEN - DAY #7#", "Lena burns the toast."),
            ("EXT. RAVINE - DAWN #8#", "The car is at the bottom.")
        ])
        var metadata = buildMetadata(for: original)

        let edited = buildScript([
            ("EXT. RAVINE - DAWN #8#", "The car is at the bottom."),
            ("INT. THE KITCHEN - DAY #7#", "Lena burns the toast again.")
        ])
        let resolution = SceneIdentityResolver.resolve(metadata, against: edited)
        metadata.reanchor(to: edited, using: resolution)

        // Records are re-sorted into document order, so the JSON diffs next to
        // the script rather than in some historical order.
        #expect(metadata.scenes.map(\.shootingDay) == [1, 0])
        #expect(metadata.scenes[0].anchor.orderIndex == 0)
        #expect(metadata.scenes[1].anchor.heading == "INT. THE KITCHEN - DAY")

        // The next open starts from an exact match rather than compounding a
        // loose one.
        let again = SceneIdentityResolver.resolve(metadata, against: edited)
        #expect(again.counts == [.sceneNumber: 2])
    }

    @Test("A record can be created for a scene that had none")
    func recordsForNewScenes() {
        let original = buildScript([("INT. KITCHEN - DAY", "Lena burns the toast.")])
        var metadata = buildMetadata(for: original)

        let edited = buildScript([
            ("INT. KITCHEN - DAY", "Lena burns the toast."),
            ("EXT. RAVINE - DAWN", "The car is at the bottom.")
        ])
        let resolution = SceneIdentityResolver.resolve(metadata, against: edited)
        let created = metadata.addRecordsForUnmatchedScenes(in: edited, using: resolution)

        #expect(created.count == 1)
        #expect(metadata.scenes.count == 2)
        #expect(metadata.scenes[1].anchor.heading == "EXT. RAVINE - DAWN")
        #expect(metadata.scenes[1].isBlank)
        #expect(SceneIdentityResolver.resolve(metadata, against: edited).counts == [.heading: 2])
    }

    @Test("A document with no metadata reports every scene as unclaimed")
    func emptyMetadata() {
        let script = buildScript([
            ("INT. KITCHEN - DAY", "Lena burns the toast."),
            ("EXT. RAVINE - DAWN", "The car is at the bottom.")
        ])
        let resolution = SceneIdentityResolver.resolve(.empty, against: script)
        #expect(resolution.matches.isEmpty)
        #expect(resolution.orphanedRecordIDs.isEmpty)
        #expect(resolution.unmatchedSceneIndices == [1, 2])
        #expect(!resolution.needsReview)
    }
}

@Suite("Scene identity against the reference corpus")
struct SceneIdentityCorpusTests {

    /// The largest script in the reference library: 91 KB, 95 scenes, every one
    /// of them numbered.
    private static var analInformant: String? {
        // Through the shared resolver, which prefers the vendored snapshot in
        // Fixtures/Corpus. Reading the user's live file made this suite depend
        // on their editing: applying lint fixes to their own screenplay changed
        // its size and broke assertions that were never about the code.
        try? Corpus.source(of: "Anal Informant/anal-informant.fountain")
    }

    /// Rebuilds a script's source with its scenes in a new order, some of them
    /// retitled, and optionally with the `#N#` numbers taken off.
    ///
    /// Works on `ScriptScene.range`, which covers a heading through the last line
    /// before the next one — the same contiguous-range property the editor will
    /// use to move a scene for real.
    static func rewrite(
        _ script: ParsedScript,
        order: [Int],
        retitles: [Int: String] = [:],
        strippingNumbers: Bool = false
    ) -> String {
        let source = script.source as NSString
        var result = source.substring(to: script.scenes[0].range.location)
        for original in order {
            let scene = script.scenes[original]
            let block = source.substring(with: scene.range)
            guard let breakIndex = block.firstIndex(of: "\n") else { continue }
            let (parsed, number) = ScriptParser.splitSceneNumber(String(block[..<breakIndex]))
            let heading = retitles[original] ?? parsed
            let suffix = (strippingNumbers ? nil : number).map { " #\($0)#" } ?? ""
            result += heading + suffix + String(block[breakIndex...])
        }
        return result
    }

    /// A realistic pass of production rewriting: a block of ten scenes lifted
    /// out of the second act and dropped thirty scenes later, plus four
    /// headings edited in place — one extended, one flipped from interior to
    /// exterior, one with a time change, and one replaced outright.
    static func edit(_ script: ParsedScript, strippingNumbers: Bool) -> (source: String, origin: [Int]) {
        let count = script.scenes.count
        let order = Array(0..<30) + Array(40..<61) + Array(30..<40) + Array(61..<count)

        let flipped = script.scenes[12].heading.contains("INT.")
            ? script.scenes[12].heading.replacingOccurrences(of: "INT.", with: "EXT.")
            : script.scenes[12].heading.replacingOccurrences(of: "EXT.", with: "INT.")
        // A time-of-day change, on whichever scene in the moved block has one.
        let nightIndex = (40..<count).first { script.scenes[$0].heading.contains("NIGHT") } ?? 45

        var retitles: [Int: String] = [
            5: script.scenes[5].heading + " - CONTINUOUS",
            12: flipped,
            nightIndex: script.scenes[nightIndex].heading
                .replacingOccurrences(of: "NIGHT", with: "LATE NIGHT"),
            70: "INT. A PLACE THAT DID NOT EXIST BEFORE - DAWN"
        ]
        // A retitle that quietly did nothing would make this exercise look
        // better than it is.
        retitles = retitles.filter { $0.value != script.scenes[$0.key].heading }
        precondition(retitles.count == 4, "The corpus edit stopped editing four headings.")
        return (rewrite(script, order: order, retitles: retitles, strippingNumbers: strippingNumbers), order)
    }

    /// Records that landed on a scene they did not come from. The number that
    /// has to be zero.
    static func misattachments(
        _ resolution: MetadataResolution,
        _ metadata: ScreenplayMetadata,
        origin: [Int]
    ) -> [(scene: Int, expected: Int, got: Int)] {
        var wrong: [(Int, Int, Int)] = []
        for match in resolution.matches {
            guard let day = metadata.record(id: match.recordID)?.shootingDay else { continue }
            let expected = origin[match.sceneIndex - 1]
            if day != expected { wrong.append((match.sceneIndex, expected, day)) }
        }
        return wrong
    }

    @Test("95 numbered scenes survive a block move and four retitles")
    func numberedScenesSurviveEverything() throws {
        let source = try #require(Self.analInformant, "Reference corpus not present on this machine.")
        let script = ScriptParser.parse(source)
        #expect(script.scenes.count == 95)

        let metadata = buildMetadata(for: script)
        let (edited, origin) = Self.edit(script, strippingNumbers: false)
        let reparsed = ScriptParser.parse(edited)
        #expect(reparsed.scenes.count == 95)

        let resolution = SceneIdentityResolver.resolve(metadata, against: reparsed)
        print("anal-informant, numbers intact: \(resolution.counts)")

        // Every one, exactly, at the strongest tier. This is what the writer
        // numbering their scenes buys: the metadata is untouchable.
        #expect(resolution.counts == [.sceneNumber: 95])
        #expect(Self.misattachments(resolution, metadata, origin: origin).isEmpty)
        #expect(!resolution.needsReview)
    }

    @Test("The same edit without scene numbers falls back through the cascade")
    func unnumberedScenesFallBack() throws {
        let source = try #require(Self.analInformant, "Reference corpus not present on this machine.")
        let script = ScriptParser.parse(source)

        // Strip the numbers from both sides: the script as re-parsed, and the
        // records, which is what a sidecar for an unnumbered script looks like.
        let plain = ScriptParser.parse(Self.rewrite(script, order: Array(0..<95), strippingNumbers: true))
        var metadata = buildMetadata(for: plain)
        #expect(metadata.scenes.allSatisfy { $0.anchor.sceneNumber == nil })

        let (edited, origin) = Self.edit(plain, strippingNumbers: true)
        let reparsed = ScriptParser.parse(edited)
        let resolution = SceneIdentityResolver.resolve(metadata, against: reparsed)

        print("anal-informant, numbers stripped: \(resolution.counts)")
        print("  orphans: \(resolution.orphanedRecordIDs.count)"
            + "  unclaimed scenes: \(resolution.unmatchedSceneIndices.count)")

        // The assertion that matters: not one record on a scene that is not its
        // own. This script repeats headings heavily — `INT. FACILITY B-7 - LAB 7
        // - CONTINUOUS` alone recurs — so the whole duplicate-disambiguation
        // path is exercised, and a block of ten scenes has moved past thirty.
        let wrong = Self.misattachments(resolution, metadata, origin: origin)
        #expect(wrong.isEmpty, "Records landed on the wrong scenes: \(wrong.prefix(5))")

        // And it is not merely safe — it is useful. Most links survive.
        #expect(resolution.matches.count >= 85)
        #expect(resolution.counts[.heading, default: 0] >= 80)

        // The scene replaced outright is the one that should have been given up.
        #expect(resolution.orphanedRecordIDs.count >= 1)

        // Re-anchoring puts the file back to exact matches for the next open.
        metadata.reanchor(to: reparsed, using: resolution)
        let again = SceneIdentityResolver.resolve(metadata, against: reparsed)
        #expect(again.counts[.heading, default: 0] >= resolution.matches.count)
    }

    @Test("Resolving a 95-scene script is not something a UI has to wait for")
    func resolutionCost() throws {
        let source = try #require(Self.analInformant, "Reference corpus not present on this machine.")
        let script = ScriptParser.parse(Self.rewrite(ScriptParser.parse(source), order: Array(0..<95), strippingNumbers: true))
        let metadata = buildMetadata(for: script)
        let (edited, _) = Self.edit(script, strippingNumbers: true)
        let reparsed = ScriptParser.parse(edited)

        _ = SceneIdentityResolver.resolve(metadata, against: reparsed)      // warm up
        // CPU time, not wall clock: this budget must bound the resolver, not
        // whatever else the machine is doing while the suite runs.
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        for _ in 0..<10 { _ = SceneIdentityResolver.resolve(metadata, against: reparsed) }
        let each = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 10_000_000

        // Runs after a reparse, which is itself ~15ms behind a 120ms debounce.
        // The budget is generous; what it catches is the fuzzy tier going
        // quadratic over the whole document instead of inside a gap.
        #expect(each < 25, "Resolution took \(String(format: "%.2f", each))ms.")
    }
}

@Suite("Heading similarity")
struct HeadingSimilarityTests {

    @Test("The threshold sits between an edited heading and a replaced one")
    func calibration() {
        func score(_ first: String, _ second: String) -> Double {
            HeadingSimilarity.score(first, second)
        }
        let threshold = HeadingSimilarity.matchThreshold

        // Edits that must survive.
        #expect(score("EXT. MOUNTAIN – MORNING", "EXT. MOUNTAIN - MORNING") == 1)
        #expect(score("I/E MONTAGE IMAGE", "I/E MONTAGE IMAGES") > threshold)
        #expect(score("EXT. LAKE – MORNING", "EXT. LAKE HOUSE – MORNING") > threshold)
        #expect(score("INT. KTICHEN - DAY", "INT. KITCHEN - DAY") > threshold)
        #expect(score("INT. CAR - NIGHT", "INT. CAR - MOVING - NIGHT") > threshold)

        // Replacements that must not.
        #expect(score("INT. GLASS HOUSE - NIGHT", "EXT. RAVINE - DAY") < 0.4)
        #expect(score("INT. GLASS HOUSE - NIGHT", "INT. SERVER ROOM - CONTINUOUS") < 0.4)

        // And the uncomfortable middle: two scenes in the same location at
        // different times of day are *not* the same scene, and score right at
        // the line. This is why the threshold is a gate and not a decision.
        #expect(score("INT. KITCHEN - DAY", "INT. KITCHEN - NIGHT") < threshold)
        #expect(score("INT. STORAGE FACILITY - CORRIDOR A", "INT. STORAGE FACILITY - CORRIDOR B") > 0.85)
    }

    @Test("Order-preserving assignment refuses to cross itself")
    func monotoneAssignment() {
        let headings = ["INT. KITCHEN - DAY", "EXT. RAVINE - DAWN", "INT. SERVER ROOM - NIGHT"]
        let records = headings.map { HeadingSimilarity.Profile(heading: $0) }
        // The same three scenes, reversed. A greedy matcher would pair all three
        // and cross every one; a monotone one keeps a single pair, because no
        // two of these three pairings can coexist without crossing.
        let scenes = headings.reversed().map { HeadingSimilarity.Profile(heading: $0) }

        let pairs = SceneIdentityResolver.orderPreservingAssignment(records: records, scenes: scenes)
        #expect(pairs.count == 1)
    }

    @Test("Short headings one letter apart are above the threshold, and that is fine")
    func shortHeadingsAreNearlyIdentical() {
        // `INT. A - DAY` and `INT. C - DAY` score 0.79 — comfortably over the
        // line. Nothing in the threshold can fix that, and nothing needs to:
        // headings this similar are matched exactly by tier 2 long before the
        // fuzzy tier is asked, and when they are not, the ambiguity margin
        // refuses them. Pinned here so the next person to raise the threshold
        // knows it would not have helped.
        #expect(HeadingSimilarity.score("INT. A - DAY", "INT. C - DAY") > HeadingSimilarity.matchThreshold)
    }

    @Test("Similarity is symmetric and bounded")
    func metricProperties() {
        let headings = [
            "INT. KITCHEN - DAY", "EXT. RAVINE - DAWN", "", "INT. KITCHEN - NIGHT"
        ]
        for first in headings {
            for second in headings {
                let forward = HeadingSimilarity.score(first, second)
                #expect(forward == HeadingSimilarity.score(second, first))
                #expect(forward >= 0 && forward <= 1)
                if first == second, !first.isEmpty { #expect(forward == 1) }
            }
        }
    }
}
