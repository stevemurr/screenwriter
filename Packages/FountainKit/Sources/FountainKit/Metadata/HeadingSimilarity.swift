import Foundation

/// How alike two scene headings are, on a 0...1 scale.
///
/// Used only by the resolver's third tier, after an exact scene number and an
/// exact heading have both failed. The question it answers is narrow: *did the
/// writer edit this heading, or replace it?*
///
/// The score blends two measures in equal parts, because each one is blind to
/// what the other sees:
///
/// - **Edit distance** over the normalised string catches a typo fix or a word
///   swap, but is blind to structure — it cannot tell that `KITCHEN` and
///   `KITCHEN` are the same word when the rest of the line moved.
/// - **Token overlap** (Sørensen–Dice over the word set) catches a reordered or
///   extended heading, but is blind to typos: one wrong letter and the token
///   stops matching at all.
///
/// A heading is a short line of five or six meaningful words, which is exactly
/// the length where either measure alone is noisy and both together are not.
public enum HeadingSimilarity {

    /// Below this, two headings are treated as different scenes.
    ///
    /// Measured, not chosen for roundness. Scoring all 331 scene headings in the
    /// reference corpus against every other heading in the same script says
    /// something uncomfortable and load-bearing:
    ///
    /// **207 of those 331 headings — 63% — have a *different* scene in the same
    /// script scoring above 0.72 against them.** Real sluglines in a
    /// location-heavy script are nearly identical to each other by construction:
    ///
    /// | genuinely different scenes, same script | score |
    /// | --- | --- |
    /// | `INT. STORAGE FACILITY - CORRIDOR A - CONTINUOUS` vs `… CORRIDOR B …` | 0.91 |
    /// | `INT. AIRBNB - LIVING ROOM - MORNING` vs `… - LATE MORNING` | 0.89 |
    /// | `EXT. ADAMS NEW HOUSE - NIGHT` vs `INT. ADAMS NEW HOUSE - NIGHT` | 0.86 |
    ///
    /// So there is no threshold that separates "the writer edited this heading"
    /// from "this is the room next door", and any design that leans on one is
    /// wrong. That work is done by the cascade instead: the real scene is
    /// claimed by an exact match *before* the fuzzy tier runs, a loose match may
    /// not cross a confident one, and a winner with a near-rival is refused
    /// outright. The threshold's only job is the coarse one — reject a heading
    /// that was *replaced* rather than edited.
    ///
    /// Against that job, 0.72 sits in the gap between the edits that must be
    /// caught and the replacements that must not be:
    ///
    /// | edit | score | |
    /// | --- | --- | --- |
    /// | `EXT. MOUNTAIN – MORNING` → `- MORNING` (en dash) | 1.00 | matches |
    /// | `I/E MONTAGE IMAGE` → `IMAGES` | 0.85 | matches |
    /// | `EXT. LAKE – MORNING` → `EXT. LAKE HOUSE – MORNING` | 0.81 | matches |
    /// | `INT. KTICHEN - DAY` → `INT. KITCHEN - DAY` (typo fix) | 0.78 | matches |
    /// | `INT. CAR - NIGHT` → `INT. CAR - MOVING - NIGHT` | 0.75 | matches |
    /// | `INT. KITCHEN - DAY` → `INT. KITCHEN` | 0.73 | matches |
    /// | `INT. KITCHEN - DAY` → `INT. KITCHEN - NIGHT` | 0.71 | refused |
    /// | `INT. BEDROOM - MORNING` → `INT. BEDROOM - LATER` | 0.67 | refused |
    /// | `INT. GLASS HOUSE - NIGHT` → `INT. SERVER ROOM - CONTINUOUS` | 0.31 | refused |
    /// | `INT. GLASS HOUSE - NIGHT` → `EXT. RAVINE - DAY` | 0.17 | refused |
    ///
    /// Changing only the time of day on a short heading falls below the line and
    /// orphans. That is the right way round: on a short heading the time of day
    /// is most of what the heading says, and it is also the single most likely
    /// difference between two scenes that genuinely are not the same one.
    public static let matchThreshold = 0.72

    /// A match is refused when a second, unclaimed candidate scores within this
    /// of the winner. Two plausible answers and no way to choose between them is
    /// the exact situation where guessing produces a wrong shooting schedule
    /// that nobody notices, so the resolver declines and reports an orphan.
    public static let ambiguityMargin = 0.08

    /// A heading pre-reduced to the two forms the score needs. Built once per
    /// scene and per record rather than once per comparison — the fuzzy tier is
    /// quadratic in the worst case, over a 95-scene script.
    public struct Profile: Sendable, Hashable {
        public let normalized: String
        let scalars: [Unicode.Scalar]
        let tokens: Set<String>

        public init(heading: String, isNormalized: Bool = false) {
            let normalized = isNormalized ? heading : SceneIdentity.normalize(heading: heading)
            self.normalized = normalized
            self.scalars = Array(normalized.unicodeScalars)
            self.tokens = HeadingSimilarity.tokens(of: normalized)
        }
    }

    /// Words, with punctuation dropped. An apostrophe stays inside a word so
    /// `lena's` is one token rather than `lena` plus a junk `s`.
    static func tokens(of normalized: String) -> Set<String> {
        var tokens: Set<String> = []
        var current = String.UnicodeScalarView()
        for scalar in normalized.unicodeScalars {
            let isWord = (scalar.value >= 0x61 && scalar.value <= 0x7A)
                || (scalar.value >= 0x30 && scalar.value <= 0x39)
                || scalar == "'"
                || scalar.value > 0x7F                    // accented letters
            if isWord {
                current.append(scalar)
            } else if !current.isEmpty {
                tokens.insert(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { tokens.insert(String(current)) }
        return tokens
    }

    /// The score for two raw headings.
    public static func score(_ first: String, _ second: String) -> Double {
        score(Profile(heading: first), Profile(heading: second))
    }

    public static func score(_ first: Profile, _ second: Profile) -> Double {
        score(first, second, atLeast: 0) ?? 0
    }

    /// The score, or nil when it provably cannot reach `floor`.
    ///
    /// The bail-out is exact, not a heuristic: the blend is half token overlap
    /// and half edit similarity, and edit similarity can never exceed 1, so a
    /// token overlap below `2 · floor − 1` cannot produce a passing score no
    /// matter what the edit distance turns out to be. Token overlap is a set
    /// intersection over six short words; edit distance is a quadratic scan. On
    /// a script whose headings were all rewritten this skips nearly every one.
    public static func score(_ first: Profile, _ second: Profile, atLeast floor: Double) -> Double? {
        if first.normalized == second.normalized { return 1 }
        if first.scalars.isEmpty || second.scalars.isEmpty { return nil }

        let overlap = dice(first.tokens, second.tokens)
        if 0.5 + 0.5 * overlap < floor { return nil }

        let distance = editDistance(first.scalars, second.scalars)
        let longest = max(first.scalars.count, second.scalars.count)
        let edit = 1 - Double(distance) / Double(longest)
        let blended = 0.5 * edit + 0.5 * overlap
        return blended < floor ? nil : blended
    }

    /// Sørensen–Dice over two token sets.
    static func dice(_ first: Set<String>, _ second: Set<String>) -> Double {
        guard !first.isEmpty, !second.isEmpty else { return 0 }
        let shared = first.intersection(second).count
        return 2 * Double(shared) / Double(first.count + second.count)
    }

    /// Levenshtein distance, two rows rather than a full matrix.
    ///
    /// Compares unicode scalars, not characters: `Character` iteration walks
    /// grapheme clusters, which the parser bans on its hot path for good reason
    /// (Rule 4) and which buys nothing here — the normalised heading has already
    /// folded the only composed forms that matter.
    static func editDistance(_ first: [Unicode.Scalar], _ second: [Unicode.Scalar]) -> Int {
        if first.isEmpty { return second.count }
        if second.isEmpty { return first.count }

        var previous = Array(0...second.count)
        var current = [Int](repeating: 0, count: second.count + 1)

        for i in 1...first.count {
            current[0] = i
            for j in 1...second.count {
                let substitution = previous[j - 1] + (first[i - 1] == second[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return previous[second.count]
    }
}
