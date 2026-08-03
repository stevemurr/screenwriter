import Foundation

/// How a record found its scene. Ordered by confidence, strongest first.
public enum MatchTier: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    /// An exact `#42#` scene number. Survives reordering, retitling, rewriting.
    case sceneNumber
    /// The same heading, with duplicates told apart by content or by position.
    case heading
    /// A heading that changed but is recognisably the same one, in a position
    /// that cannot have crossed a confident match. Show this differently in the
    /// UI — it is a proposal, not a fact.
    case fuzzy
    /// No scene. The record is kept; the link is not.
    case orphan

    /// `<` means *more* confident.
    public static func < (lhs: MatchTier, rhs: MatchTier) -> Bool {
        lhs.rank < rhs.rank
    }

    var rank: Int {
        switch self {
        case .sceneNumber: return 0
        case .heading: return 1
        case .fuzzy: return 2
        case .orphan: return 3
        }
    }

    /// True for a match a UI can present without asking the user to confirm it.
    public var isConfident: Bool { self == .sceneNumber || self == .heading }
}

/// One record, matched to one scene.
public struct SceneMatch: Sendable, Hashable {
    public var recordID: UUID
    /// One-based, matching `ScriptScene.index`.
    public var sceneIndex: Int
    public var tier: MatchTier
    /// Only set for `.fuzzy`, so the UI can say *how* unsure it is.
    public var similarity: Double?

    public init(recordID: UUID, sceneIndex: Int, tier: MatchTier, similarity: Double? = nil) {
        self.recordID = recordID
        self.sceneIndex = sceneIndex
        self.tier = tier
        self.similarity = similarity
    }
}

/// What the resolver decided, in full.
///
/// Every record is accounted for exactly once: it is in `matches` or in
/// `orphanedRecordIDs`. Nothing is dropped, and nothing is matched without
/// saying how — "3 scenes lost their metadata" and "this one matched loosely,
/// check it" are both things the UI has to be able to say.
public struct MetadataResolution: Sendable {
    public var matches: [SceneMatch]
    /// Records that resolved to nothing. Kept in the file, not deleted.
    public var orphanedRecordIDs: [UUID]
    /// One-based indices of scenes no record claimed — new scenes, or scenes
    /// whose record was orphaned.
    public var unmatchedSceneIndices: [Int]

    private let matchByRecord: [UUID: SceneMatch]
    private let matchBySceneIndex: [Int: SceneMatch]

    public init(
        matches: [SceneMatch],
        orphanedRecordIDs: [UUID],
        unmatchedSceneIndices: [Int]
    ) {
        self.matches = matches
        self.orphanedRecordIDs = orphanedRecordIDs
        self.unmatchedSceneIndices = unmatchedSceneIndices
        self.matchByRecord = Dictionary(
            matches.map { ($0.recordID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.matchBySceneIndex = Dictionary(
            matches.map { ($0.sceneIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    public static let empty = MetadataResolution(
        matches: [], orphanedRecordIDs: [], unmatchedSceneIndices: []
    )

    public func sceneIndex(for recordID: UUID) -> Int? { matchByRecord[recordID]?.sceneIndex }

    public func match(for recordID: UUID) -> SceneMatch? { matchByRecord[recordID] }

    public func match(forSceneAt index: Int) -> SceneMatch? { matchBySceneIndex[index] }

    /// `.orphan` for a record that matched nothing — every record has a tier.
    public func tier(for recordID: UUID) -> MatchTier {
        matchByRecord[recordID]?.tier ?? .orphan
    }

    /// Hit counts per tier, orphans included. The number the UI puts in front of
    /// the user after a big edit.
    public var counts: [MatchTier: Int] {
        var counts: [MatchTier: Int] = [:]
        for match in matches { counts[match.tier, default: 0] += 1 }
        if !orphanedRecordIDs.isEmpty { counts[.orphan] = orphanedRecordIDs.count }
        return counts
    }

    /// True when nothing needs a human to look at it.
    public var needsReview: Bool {
        !orphanedRecordIDs.isEmpty || matches.contains { !$0.tier.isConfident }
    }
}

/// Maps stored records onto the scenes of a freshly parsed script.
///
/// Scenes get reordered, retyped, split, merged and deleted, and metadata is
/// keyed to them. The dangerous failure is not losing a link — that is visible
/// and recoverable — it is attaching a shooting day to the wrong scene, which
/// nobody notices until the schedule is wrong. Every rule here is chosen to fail
/// towards the orphan.
///
/// The cascade, strongest first:
///
/// 1. **Scene number.** `#42#` is an explicit, writer-authored identifier that
///    survives every edit except deleting it. Matched only when the number is
///    unique on both sides: two scenes numbered `42` is a real thing that
///    happens after a copy-paste, and a coin flip between them is exactly what
///    this resolver must not do.
/// 2. **Normalised heading.** Case, whitespace and dash shape folded. When a
///    heading occurs once, that is the answer. When it occurs several times, the
///    content fingerprint tells the copies apart, and failing that their ordinal
///    does — but only when no scene with that heading was added or deleted,
///    since otherwise the ordinals have shifted and pairing them is what slides
///    a whole run of metadata by one.
/// 3. **Fuzzy heading**, constrained two ways. A match must score above
///    `HeadingSimilarity.matchThreshold`, and it may not cross a scene that
///    tiers 1 and 2 already claimed: the confident matches form a spine, and a
///    loose match may only land in the gap between the two that bracket it.
///    Within a gap the assignment is order-preserving, so matches cannot cross
///    each other either. A winner with a rival within
///    `HeadingSimilarity.ambiguityMargin` is refused outright.
/// 4. **Orphan.** Retained and reported.
public enum SceneIdentityResolver {

    public static func resolve(
        _ metadata: ScreenplayMetadata,
        against script: ParsedScript
    ) -> MetadataResolution {
        let scenes = script.scenes
        // Records in the document order they were last saved in. Ties break on
        // array position so the result never depends on dictionary ordering.
        let records = metadata.scenes.enumerated()
            .sorted { ($0.element.anchor.orderIndex, $0.offset) < ($1.element.anchor.orderIndex, $1.offset) }
            .map(\.element)

        guard !records.isEmpty else {
            return MetadataResolution(
                matches: [],
                orphanedRecordIDs: [],
                unmatchedSceneIndices: scenes.map(\.index)
            )
        }

        let sceneProfiles = scenes.map { HeadingSimilarity.Profile(heading: $0.heading) }
        let sceneHashes = scenes.map { SceneIdentity.contentHash(for: $0, in: script) }
        let recordProfiles = records.map { HeadingSimilarity.Profile(heading: $0.anchor.heading) }

        // Scene slots are zero-based into `scenes`; `ScriptScene.index` is one-based.
        var claimant = [Int?](repeating: nil, count: scenes.count)
        var assignedSlot = [Int?](repeating: nil, count: records.count)
        var assignedTier = [MatchTier?](repeating: nil, count: records.count)
        var assignedScore = [Double?](repeating: nil, count: records.count)

        func claim(record position: Int, scene slot: Int, tier: MatchTier, score: Double? = nil) {
            guard assignedSlot[position] == nil, claimant[slot] == nil else { return }
            claimant[slot] = position
            assignedSlot[position] = slot
            assignedTier[position] = tier
            assignedScore[position] = score
        }

        // --- Tier 1: scene number ------------------------------------------
        var slotsByNumber: [String: [Int]] = [:]
        for slot in scenes.indices {
            guard let number = SceneIdentity.normalize(number: scenes[slot].number) else { continue }
            slotsByNumber[number, default: []].append(slot)
        }
        var positionsByNumber: [String: [Int]] = [:]
        for position in records.indices {
            guard let number = records[position].anchor.normalizedNumber else { continue }
            positionsByNumber[number, default: []].append(position)
        }
        // Sorted for determinism only; each claim below is independent.
        for (number, positions) in positionsByNumber.sorted(by: { $0.key < $1.key }) {
            guard positions.count == 1,
                  let slots = slotsByNumber[number], slots.count == 1 else { continue }
            claim(record: positions[0], scene: slots[0], tier: .sceneNumber)
        }

        // --- Tier 2: normalised heading, with duplicates disambiguated ------
        var slotsByHeading: [String: [Int]] = [:]
        for slot in scenes.indices where claimant[slot] == nil {
            slotsByHeading[sceneProfiles[slot].normalized, default: []].append(slot)
        }
        var positionsByHeading: [String: [Int]] = [:]
        var headingOrder: [String] = []
        for position in records.indices where assignedSlot[position] == nil {
            let heading = recordProfiles[position].normalized
            if positionsByHeading[heading] == nil { headingOrder.append(heading) }
            positionsByHeading[heading, default: []].append(position)
        }

        for heading in headingOrder {
            var positions = positionsByHeading[heading] ?? []
            var slots = slotsByHeading[heading] ?? []
            guard !slots.isEmpty else { continue }

            if positions.count == 1, slots.count == 1 {
                claim(record: positions[0], scene: slots[0], tier: .heading)
                continue
            }

            // The heading is ambiguous, so ask the bodies. A fingerprint that is
            // unique on both sides is stronger evidence than position: it is
            // what makes swapping two identical sluglines carry their shooting
            // days with them instead of leaving them behind.
            var slotsByHash: [String: [Int]] = [:]
            for slot in slots {
                guard let hash = sceneHashes[slot] else { continue }
                slotsByHash[hash, default: []].append(slot)
            }
            var positionsByHash: [String: [Int]] = [:]
            for position in positions {
                guard let hash = records[position].anchor.contentHash else { continue }
                positionsByHash[hash, default: []].append(position)
            }
            for (hash, hashPositions) in positionsByHash.sorted(by: { $0.key < $1.key }) {
                guard hashPositions.count == 1,
                      let hashSlots = slotsByHash[hash], hashSlots.count == 1 else { continue }
                claim(record: hashPositions[0], scene: hashSlots[0], tier: .heading)
            }

            positions = positions.filter { assignedSlot[$0] == nil }
            slots = slots.filter { claimant[$0] == nil }

            // Ordinal among the duplicates, and only when the counts still
            // agree. Unequal counts mean a scene with this heading was added or
            // deleted, so the ordinals no longer line up and pairing them would
            // shift every record after the change onto its neighbour. Those
            // fall through to the fuzzy tier, where the ordering constraint gets
            // a say.
            guard !positions.isEmpty, positions.count == slots.count else { continue }
            for (position, slot) in zip(positions, slots) {
                claim(record: position, scene: slot, tier: .heading)
            }
        }

        // --- Tier 3: fuzzy heading, inside the gaps between confident matches -
        var spine: [(record: Int, slot: Int)] = []
        for position in records.indices {
            guard let slot = assignedSlot[position] else { continue }
            spine.append((position, slot))
        }

        for gap in 0...spine.count {
            let recordLow = gap == 0 ? -1 : spine[gap - 1].record
            let recordHigh = gap == spine.count ? records.count : spine[gap].record
            let slotLow = gap == 0 ? -1 : spine[gap - 1].slot
            let slotHigh = gap == spine.count ? scenes.count : spine[gap].slot

            let gapRecords = ((recordLow + 1)..<recordHigh).filter { assignedSlot[$0] == nil }
            // Empty when the bracketing matches are out of order, which is what
            // a moved block looks like from here: no loose match is allowed to
            // reach across a confident one, so the whole block orphans rather
            // than sliding onto its neighbours.
            let gapSlots = slotLow < slotHigh
                ? ((slotLow + 1)..<slotHigh).filter { claimant[$0] == nil }
                : []
            guard !gapRecords.isEmpty, !gapSlots.isEmpty else { continue }

            let pairs = orderPreservingAssignment(
                records: gapRecords.map { recordProfiles[$0] },
                scenes: gapSlots.map { sceneProfiles[$0] }
            )

            let takenScenes = Set(pairs.map(\.scene))
            let takenRecords = Set(pairs.map(\.record))
            for pair in pairs {
                // Refuse when a second candidate is nearly as good and nothing
                // else claimed it. One plausible answer is a match; two is a
                // coin flip, and a coin flip is how a shooting day ends up on
                // the wrong scene.
                let cutoff = pair.score - HeadingSimilarity.ambiguityMargin
                let rivalScene = gapSlots.indices.contains { other in
                    guard other != pair.scene, !takenScenes.contains(other) else { return false }
                    return HeadingSimilarity.score(
                        recordProfiles[gapRecords[pair.record]],
                        sceneProfiles[gapSlots[other]],
                        atLeast: cutoff
                    ) != nil
                }
                let rivalRecord = gapRecords.indices.contains { other in
                    guard other != pair.record, !takenRecords.contains(other) else { return false }
                    return HeadingSimilarity.score(
                        recordProfiles[gapRecords[other]],
                        sceneProfiles[gapSlots[pair.scene]],
                        atLeast: cutoff
                    ) != nil
                }
                guard !rivalScene, !rivalRecord else { continue }
                claim(
                    record: gapRecords[pair.record],
                    scene: gapSlots[pair.scene],
                    tier: .fuzzy,
                    score: pair.score
                )
            }
        }

        // --- Tier 4: orphans ------------------------------------------------
        var matches: [SceneMatch] = []
        var orphans: [UUID] = []
        for position in records.indices {
            guard let slot = assignedSlot[position], let tier = assignedTier[position] else {
                orphans.append(records[position].id)
                continue
            }
            matches.append(
                SceneMatch(
                    recordID: records[position].id,
                    sceneIndex: scenes[slot].index,
                    tier: tier,
                    similarity: assignedScore[position]
                )
            )
        }
        let unmatched = scenes.indices.filter { claimant[$0] == nil }.map { scenes[$0].index }

        return MetadataResolution(
            matches: matches,
            orphanedRecordIDs: orphans,
            unmatchedSceneIndices: unmatched
        )
    }

    /// The best set of pairings between two runs of headings that preserves
    /// order — no pairing may cross another.
    ///
    /// Order preservation is the whole point. Greedily taking the best score
    /// first is what lets one strong match in the wrong place drag everything
    /// after it out of alignment; requiring a monotone assignment means a
    /// deleted scene costs one match rather than shifting every match that
    /// follows it. It is the same needle as a diff, and the same dynamic
    /// programme: `O(records × scenes)` over a gap, which is a handful of scenes
    /// in every case but a script whose headings were all rewritten at once.
    ///
    /// Indices are into the arrays passed in, not scene slots.
    static func orderPreservingAssignment(
        records: [HeadingSimilarity.Profile],
        scenes: [HeadingSimilarity.Profile]
    ) -> [(record: Int, scene: Int, score: Double)] {
        let rows = records.count
        let columns = scenes.count
        guard rows > 0, columns > 0 else { return [] }

        var similarity = [[Double?]](
            repeating: [Double?](repeating: nil, count: columns), count: rows
        )
        for row in 0..<rows {
            for column in 0..<columns {
                similarity[row][column] = HeadingSimilarity.score(
                    records[row], scenes[column], atLeast: HeadingSimilarity.matchThreshold
                )
            }
        }

        var best = [[Double]](repeating: [Double](repeating: 0, count: columns + 1), count: rows + 1)
        for row in 1...rows {
            for column in 1...columns {
                var value = max(best[row - 1][column], best[row][column - 1])
                if let score = similarity[row - 1][column - 1] {
                    value = max(value, best[row - 1][column - 1] + score)
                }
                best[row][column] = value
            }
        }

        var pairs: [(record: Int, scene: Int, score: Double)] = []
        var row = rows
        var column = columns
        while row > 0, column > 0 {
            if let score = similarity[row - 1][column - 1],
               best[row][column] == best[row - 1][column - 1] + score {
                pairs.append((row - 1, column - 1, score))
                row -= 1
                column -= 1
            } else if best[row - 1][column] >= best[row][column - 1] {
                row -= 1
            } else {
                column -= 1
            }
        }
        return pairs.reversed()
    }
}
