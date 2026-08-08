import Foundation
import Testing
@testable import FountainKit

@Suite("A script remembers what it has already called things")
struct VocabularyTests {

    private let source = """
    INT. DINER - NIGHT

    Rain sheets the window.

    MARLA
    You said ten.

    DEL (V.O.)
    Traffic.

    MARLA (CONT'D)
    Which one is the lie?

    EXT. PARKING LOT - CONTINUOUS

    Neon.

    INT. DINER - DAY

    Morning.
    """

    @Test("Cast is ranked by how often it speaks")
    func castRanking() {
        let vocabulary = ScriptVocabulary(script: ScriptParser.parse(source))
        #expect(vocabulary.characters == ["MARLA", "DEL"], "MARLA speaks twice, DEL once")
    }

    @Test("A cue's extension is not part of the name")
    func extensionsAreStripped() {
        let vocabulary = ScriptVocabulary(script: ScriptParser.parse(source))
        #expect(!vocabulary.characters.contains { $0.contains("(") })
    }

    @Test("Locations and times come off the headings, most used first")
    func headings() {
        let vocabulary = ScriptVocabulary(script: ScriptParser.parse(source))
        #expect(vocabulary.locations == ["DINER", "PARKING LOT"])
        // NIGHT, CONTINUOUS and DAY are each used once, so first appearance
        // orders them; the conventional ones follow, without duplicates.
        #expect(vocabulary.timesOfDay.prefix(3) == ["NIGHT", "CONTINUOUS", "DAY"])
        #expect(Set(vocabulary.timesOfDay).count == vocabulary.timesOfDay.count)
        #expect(vocabulary.timesOfDay.contains("DAWN"), "conventional times are always offered")
    }

    @Test("A blank script still knows the conventional times of day")
    func blankScript() {
        let vocabulary = ScriptVocabulary(script: ScriptParser.parse(""))
        #expect(vocabulary.characters.isEmpty)
        #expect(vocabulary.locations.isEmpty)
        #expect(vocabulary.timesOfDay == ScriptVocabulary.conventionalTimesOfDay)
    }

    @Test("A location containing a dash is not split at the wrong one")
    func dashesInsideLocations() {
        let parts = SceneHeading.split("INT. WELL-HOUSE BASEMENT - PRE-DAWN")
        #expect(parts.prefix == "INT.")
        #expect(parts.location == "WELL-HOUSE BASEMENT")
        #expect(parts.timeOfDay == "PRE-DAWN")
    }

    /// A room inside a place. `Clean Break` in the corpus writes a dozen of
    /// these off one house, and splitting at the *first* separator would file
    /// them all under "AIRBNB" and offer that as the only location.
    @Test("A compound location survives whole")
    func compoundLocations() {
        let parts = SceneHeading.split("INT. AIRBNB - LIVING ROOM - NIGHT")
        #expect(parts.location == "AIRBNB - LIVING ROOM")
        #expect(parts.timeOfDay == "NIGHT")

        let vocabulary = ScriptVocabulary(script: ScriptParser.parse("""
        INT. AIRBNB - KITCHEN - NIGHT

        A kettle.

        INT. AIRBNB - PORCH - DAY

        Morning.
        """))
        #expect(vocabulary.locations == ["AIRBNB - KITCHEN", "AIRBNB - PORCH"])
        // And typing the house offers both rooms.
        #expect(Completion.matching("AIRBNB", in: vocabulary.locations).count == 2)
    }

    /// The corpus writes `EXT. MOUNTAIN – MORNING` with an en dash, and the
    /// linter flags it rather than refusing it — so the vocabulary has to read
    /// it too, or those headings contribute a location of `MOUNTAIN – MORNING`.
    @Test("En-dash headings split like hyphenated ones")
    func enDashHeadings() {
        let parts = SceneHeading.split("EXT. MOUNTAIN – MORNING")
        #expect(parts.location == "MOUNTAIN")
        #expect(parts.timeOfDay == "MORNING")
    }

    /// `.` forces a scene heading, and one script in the corpus uses `.` as a
    /// general beat prefix — so the parser sees `.- stair case problem` as a
    /// heading and the location list would offer a line of somebody's notes.
    @Test("Notes forced into headings are not offered as locations")
    func malformedHeadingsAreNotLocations() {
        let beats = """
        .- stair case problem

        .- Alex wants to hack reality, upend existing power structures and watch it burn.

        INT. DINER - NIGHT

        Real.
        """
        let vocabulary = ScriptVocabulary(script: ScriptParser.parse(beats))
        #expect(vocabulary.locations == ["DINER"])
        #expect(!SceneHeading.isPlausibleLocation("- stair case problem"))
        #expect(SceneHeading.isPlausibleLocation("AIRBNB - LIVING ROOM"))
    }

    @Test("Every heading in the corpus yields a location")
    func acrossTheCorpus() throws {
        guard !Corpus.relativePaths.isEmpty else {
            Corpus.recordAbsence("VocabularyTests.acrossTheCorpus")
            return
        }
        for path in Corpus.relativePaths {
            let script = ScriptParser.parse(try Corpus.source(of: path))
            let vocabulary = ScriptVocabulary(script: script)
            // A compound location keeps both halves — `INT. AIRBNB - KITCHEN -
            // NIGHT` is a room inside a place, and splitting at the *first*
            // separator would file a dozen rooms of one house under "AIRBNB".
            // Taking the last one is why `Clean Break` completes to
            // "AIRBNB - KITCHEN". What must never survive is a dangling
            // separator or a location that is really a time of day.
            for location in vocabulary.locations {
                #expect(!location.isEmpty)
                #expect(
                    location == location.trimmingCharacters(in: .whitespaces),
                    Comment(rawValue: "\(path): untrimmed location: \(location)")
                )
                for tail in ["-", "–", "—"] {
                    #expect(
                        !location.hasSuffix(tail) && !location.hasPrefix(tail),
                        Comment(rawValue: "\(path): dangling separator on \(location)")
                    )
                }
            }
            for name in vocabulary.characters {
                #expect(!name.contains("("), Comment(rawValue: "\(path): cue extension in \(name)"))
                #expect(!name.hasSuffix("^"), Comment(rawValue: "\(path): dual mark in \(name)"))
            }
        }
    }
}

@Suite("Completion knows what the caret is typing")
struct CompletionTests {

    private let script = """
    INT. DINER - NIGHT

    Rain sheets the window.

    MARLA
    You said ten.

    EXT. PARKING LOT - CONTINUOUS

    Neon.
    """

    private func suggest(_ source: String, caretAfter marker: String) -> Completion.Result? {
        let ns = source as NSString
        let range = ns.range(of: marker)
        guard range.location != NSNotFound else { return nil }
        return Completion.suggest(
            in: ns,
            caret: NSMaxRange(range),
            vocabulary: ScriptVocabulary(script: ScriptParser.parse(script))
        )
    }

    @Test("A cue completes from the cast")
    func characterCue() throws {
        let result = try #require(suggest("INT. ROOM - DAY\n\nMAR", caretAfter: "MAR"))
        #expect(result.kind == .character)
        #expect(result.suggestions == ["MARLA"])
        #expect(result.prefix == "MAR")
    }

    @Test("A forced cue completes without needing a blank line above")
    func forcedCue() throws {
        let result = try #require(suggest("Some action.\n@MAR", caretAfter: "@MAR"))
        #expect(result.kind == .character)
        #expect(result.suggestions == ["MARLA"])
        // The `@` is not replaced — only the name after it.
        #expect(result.range.length == 3)
    }

    /// The case that makes this delicate: action is often uppercase, and the
    /// parser cannot tell it from a cue until the line below exists.
    @Test("Uppercase action offers nothing when no name matches")
    func uppercaseActionIsNotACue() {
        #expect(suggest("INT. ROOM - DAY\n\nTHE DOOR SLAMS", caretAfter: "THE DOOR SLAMS") == nil)
    }

    @Test("Lowercase is prose, never a cue")
    func lowercaseIsNotACue() {
        #expect(suggest("INT. ROOM - DAY\n\nMarla waits", caretAfter: "Marla waits") == nil)
    }

    @Test("Mid-line the caret is editing, not writing")
    func caretMustBeAtTheEnd() {
        let source = "INT. ROOM - DAY\n\nMARLA is here"
        let ns = source as NSString
        let caret = ns.range(of: "MAR").location + 3
        #expect(
            Completion.suggest(
                in: ns, caret: caret,
                vocabulary: ScriptVocabulary(script: ScriptParser.parse(script))
            ) == nil
        )
    }

    @Test("A heading completes its location")
    func location() throws {
        let result = try #require(suggest("INT. PARK", caretAfter: "INT. PARK"))
        #expect(result.kind == .location)
        #expect(result.suggestions == ["PARKING LOT"])
    }

    @Test("A word inside a location matches, a fragment does not")
    func locationWordMatching() throws {
        let result = try #require(suggest("INT. LOT", caretAfter: "INT. LOT"))
        #expect(result.suggestions == ["PARKING LOT"], "LOT is the start of a word in it")
        #expect(suggest("INT. ARK", caretAfter: "INT. ARK") == nil, "a bare substring is not a match")
    }

    @Test("After the separator it completes the time of day")
    func timeOfDay() throws {
        let result = try #require(suggest("INT. DINER - NIG", caretAfter: "NIG"))
        #expect(result.kind == .timeOfDay)
        #expect(result.suggestions == ["NIGHT"])
    }

    @Test("A forced heading completes too")
    func forcedHeading() throws {
        let result = try #require(suggest(".INT. PARK", caretAfter: ".INT. PARK"))
        #expect(result.kind == .location)
        #expect(result.suggestions == ["PARKING LOT"])
    }

    @Test("The prefix itself is not a location")
    func prefixAlone() {
        #expect(suggest("INT", caretAfter: "INT") == nil)
        #expect(suggest("INT. DINER -", caretAfter: "-") == nil, "on the way to a time of day")
    }

    /// Replacing the range must reconstruct the line, or accepting a suggestion
    /// corrupts the heading.
    @Test("The replacement range covers exactly the token being typed")
    func replacementRange() throws {
        for (line, marker, expected) in [
            ("INT. PARK", "PARK", "PARK"),
            ("INT. DINER - NIG", "NIG", "NIG"),
            ("INT. ROOM - DAY\n\nMAR", "MAR", "MAR")
        ] {
            let result = try #require(suggest(line, caretAfter: marker))
            #expect((line as NSString).substring(with: result.range) == expected)
        }
    }
}
