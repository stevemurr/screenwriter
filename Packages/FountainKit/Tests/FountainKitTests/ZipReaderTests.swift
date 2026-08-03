import Foundation
import Testing
@testable import FountainKit

/// `ZipReader` is the reason FountainKit still has zero dependencies. These
/// tests hold that line: if the reader ever stops being correct, the honest
/// answer is to fix it here, not to add a package.
///
/// The fixture is embedded rather than generated, so this suite proves both
/// compression methods and a broken filename work on a machine with no corpus,
/// no network, and no `/usr/bin/zip`.
@Suite("Zip reader")
struct ZipReaderTests {

    /// A miniature `.highland`: four `Stored` entries, one `Deflated`, two
    /// directory entries, and one filename whose bytes are not valid UTF-8 —
    /// with the archive's own UTF-8 flag cleared, exactly as the real corpus
    /// leaves it on every deflated entry.
    static let fixture = Data(
        base64Encoded:
        "UEsDBAoAAAAAAJIDA13wyR1aDQAAAA0AAAAZAAAARGVtby50ZXh0YnVuZGxlL2luZm8uanNv" +
        "bnsidmVyc2lvbiI6Mn1QSwMECgAAAAAAkgMDXQAAAAAAAAAAAAAAABcAAABEZW1vLnRleHRi" +
        "dW5kbGUvYXNzZXRzL1BLAwQKAAAAAACSAwNdiw0Rk0gAAABIAAAAIgAAAERlbW8udGV4dGJ1" +
        "bmRsZS9hc3NldHMvY//+w6nMgS5wbmeJUE5HDQoaCjnk9mW0lhefafG9xbs6oHRfmTtbH1sY" +
        "QRC/0PbmD7NpBbKvXPYLEBrsbKTJp++8rUw+JfqmXNsDvKc+Z+O8ZkxQSwMECgAAAAAAkgMD" +
        "XQAAAAAAAAAAAAAAABoAAABEZW1vLnRleHRidW5kbGUvcmVzb3VyY2VzL1BLAwQKAAAAAACS" +
        "AwNd8WDUFCgAAAAoAAAAJwAAAERlbW8udGV4dGJ1bmRsZS9yZXNvdXJjZXMvc2V0dGluZ3Mu" +
        "anNvbnsicHJpbnRTZXR0aW5ncyI6eyJwcmludFNlY3Rpb25zIjp0cnVlfX1QSwMEFAACAAgA" +
        "kgMDXf3DVfM3AAAAJAQAAB0AAABEZW1vLnRleHRidW5kbGUvdGV4dC5mb3VudGFpbvP0C9FT" +
        "8PYMcfZw9VPQVXBxjOTiCkrMzFPIS01NyUktVijJSFUoz8xLyS8v1huVGZUZlRlxMgBQSwEC" +
        "HgMKAAAAAACSAwNd8MkdWg0AAAANAAAAGQAAAAAAAAAAAAAApIEAAAAARGVtby50ZXh0YnVu" +
        "ZGxlL2luZm8uanNvblBLAQIeAwoAAAAAAJIDA10AAAAAAAAAAAAAAAAXAAAAAAAAAAAAEADt" +
        "QUQAAABEZW1vLnRleHRidW5kbGUvYXNzZXRzL1BLAQIeAwoAAAAAAJIDA12LDRGTSAAAAEgA" +
        "AAAiAAAAAAAAAAAAAACkgXkAAABEZW1vLnRleHRidW5kbGUvYXNzZXRzL2P//sOpzIEucG5n" +
        "UEsBAh4DCgAAAAAAkgMDXQAAAAAAAAAAAAAAABoAAAAAAAAAAAAQAO1BAQEAAERlbW8udGV4" +
        "dGJ1bmRsZS9yZXNvdXJjZXMvUEsBAh4DCgAAAAAAkgMDXfFg1BQoAAAAKAAAACcAAAAAAAAA" +
        "AAAAAKSBOQEAAERlbW8udGV4dGJ1bmRsZS9yZXNvdXJjZXMvc2V0dGluZ3MuanNvblBLAQIe" +
        "AxQAAgAIAJIDA139w1XzNwAAACQEAAAdAAAAAAAAAAEAAACkgaYBAABEZW1vLnRleHRidW5k" +
        "bGUvdGV4dC5mb3VudGFpblBLBQYAAAAABgAGAMQBAAAYAgAAAAA="
    )!

    static let fixtureText = "INT. KITCHEN - DAY\n\n"
        + String(repeating: "Rain needles the windows.\n", count: 40)

    @Test("The fixture really does exercise both compression methods")
    func fixtureCoversBothMethods() throws {
        let reader = try ZipReader(data: Self.fixture)
        let files = reader.entries.filter { !$0.isDirectory }
        #expect(files.contains { $0.compressionMethod == 0 })
        #expect(files.contains { $0.compressionMethod == 8 })
        #expect(reader.entries.filter(\.isDirectory).count == 2)
    }

    @Test("A stored entry is copied out byte for byte")
    func storedEntry() throws {
        let reader = try ZipReader(data: Self.fixture)
        let entry = try #require(reader["Demo.textbundle/info.json"])
        #expect(entry.compressionMethod == 0)
        #expect(try reader.data(for: entry) == Data(#"{"version":2}"#.utf8))
    }

    @Test("A deflated entry inflates to its recorded size")
    func deflatedEntry() throws {
        let reader = try ZipReader(data: Self.fixture)
        let entry = try #require(reader["Demo.textbundle/text.fountain"])
        #expect(entry.compressionMethod == 8)
        #expect(entry.compressedSize < entry.uncompressedSize)
        let data = try reader.data(for: entry)
        #expect(data.count == entry.uncompressedSize)
        #expect(data == Data(Self.fixtureText.utf8))
    }

    @Test("Directory entries carry no payload")
    func directoryEntries() throws {
        let reader = try ZipReader(data: Self.fixture)
        let entry = try #require(reader["Demo.textbundle/assets/"])
        #expect(entry.isDirectory)
        #expect(try reader.data(for: entry).isEmpty)
    }

    /// A PNG asset with an unreadable name must not cost us the screenplay
    /// three entries later. Two bundles in the reference library carry names
    /// that were already mangled when Highland saved them.
    @Test("An undecodable filename is decoded leniently, not thrown on")
    func lenientFilenames() throws {
        let reader = try ZipReader(data: Self.fixture)
        let png = try #require(reader.entries.first { $0.name.hasSuffix(".png") })
        #expect(png.nameBytes.contains(0xFF))
        #expect(String(data: Data(png.nameBytes), encoding: .utf8) == nil)
        #expect(png.name.contains("\u{FFFD}"))
        #expect(try reader.data(for: png).prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        // And the rest of the archive is unaffected.
        #expect(reader["Demo.textbundle/text.fountain"] != nil)
    }

    @Test("A damaged payload is caught by its checksum, not returned")
    func checksumMismatch() throws {
        var damaged = Self.fixture
        let marker = Data(#"{"version":2}"#.utf8)
        let range = try #require(damaged.range(of: marker))
        damaged.replaceSubrange(range, with: Data(#"{"version":9}"#.utf8))

        let reader = try ZipReader(data: damaged)
        let entry = try #require(reader["Demo.textbundle/info.json"])
        #expect(throws: ZipError.checksumMismatch("Demo.textbundle/info.json")) {
            _ = try reader.data(for: entry)
        }
    }

    @Test("Something that isn’t a zip is refused, not guessed at")
    func notAZip() {
        #expect(throws: ZipError.notAZipArchive) {
            _ = try ZipReader(data: Data("INT. KITCHEN - DAY\n".utf8))
        }
        #expect(throws: ZipError.notAZipArchive) {
            _ = try ZipReader(data: Data())
        }
    }

    /// The reference library contains one genuinely corrupt archive, so damaged
    /// input is not hypothetical. A throw is fine; a trap is not, because a
    /// trap cannot be caught and takes the app down on a file the user merely
    /// tried to open. Every byte of the central directory and the record after
    /// it is flipped in turn.
    @Test("Corrupting any header byte throws, and never traps")
    func corruptionIsSurvivable() {
        let tail = 260  // Comfortably covers the central directory and the EOCD.
        for offset in (Self.fixture.count - tail)..<Self.fixture.count {
            for mask in [UInt8(0xFF), 0x01, 0x80] {
                var damaged = Self.fixture
                damaged[offset] ^= mask
                guard let reader = try? ZipReader(data: damaged) else { continue }
                for entry in reader.entries {
                    _ = try? reader.data(for: entry)
                }
            }
        }
    }

    /// The zip64 sentinels specifically: single bit flips never produce
    /// `0xFFFFFFFF`, so that branch has to be reached deliberately. Its fields
    /// are 64-bit, and `Int(_:)` traps above `Int.max` — a crash rather than an
    /// error on a file the user merely opened.
    @Test("A zip64 claim backed by garbage throws, and never traps")
    func hostileZip64() throws {
        var hostile = Self.fixture
        let eocd = try #require(hostile.range(of: Data([0x50, 0x4B, 0x05, 0x06]))).lowerBound

        // Claim zip64 by writing the sentinel into the directory offset...
        hostile.replaceSubrange(
            (eocd + 16)..<(eocd + 20), with: Data([0xFF, 0xFF, 0xFF, 0xFF])
        )
        // ...with no zip64 locator behind it at all.
        #expect(throws: ZipError.zip64Unsupported) { _ = try ZipReader(data: hostile) }

        // And again with a locator whose 64-bit offset is past `Int.max`.
        hostile.replaceSubrange(
            (eocd - 20)..<eocd,
            with: Data([0x50, 0x4B, 0x06, 0x07] + [0, 0, 0, 0]
                + [UInt8](repeating: 0xFF, count: 8) + [0, 0, 0, 0])
        )
        #expect(throws: ZipError.zip64Unsupported) { _ = try ZipReader(data: hostile) }
    }

    @Test("A truncated archive is refused rather than half-read")
    func truncated() throws {
        // Losing the tail loses the end-of-central-directory record.
        let short = Self.fixture.prefix(Self.fixture.count - 40)
        #expect(throws: ZipError.notAZipArchive) {
            _ = try ZipReader(data: Data(short))
        }
    }

    // MARK: - The real library

    /// The measured shape of the reference corpus. `The Gig Economy Script`
    /// is genuinely damaged — see `HighlandImportTests`.
    @Test("Every archive in the reference library parses, with both methods")
    func referenceLibrary() throws {
        let bundles = try #require(
            HighlandCorpus.bundles,
            "Reference corpus not present on this machine."
        )
        #expect(bundles.count == 59)

        var stored = 0
        var deflated = 0
        var directories = 0
        var other: [UInt16] = []
        var unreadable: [String] = []

        for url in bundles {
            guard let reader = try? ZipReader(data: Data(contentsOf: url)) else {
                unreadable.append(url.lastPathComponent)
                continue
            }
            for entry in reader.entries {
                switch entry.compressionMethod {
                case 0: stored += 1
                case 8: deflated += 1
                default: other.append(entry.compressionMethod)
                }
                if entry.isDirectory { directories += 1; continue }
                // Every byte, not just the payload: this is what proves the
                // 350 KB screenshots and the 213 KB revision blobs decode too,
                // and every one of them is checked against its CRC-32.
                #expect(throws: Never.self) { _ = try reader.data(for: entry) }
            }
        }

        #expect(unreadable == HighlandCorpus.knownDamaged)
        #expect(other.isEmpty, "Unexpected compression methods: \(Set(other).sorted())")
        // The split recorded in CLAUDE.md, remeasured: 344 stored, of which 95
        // are the zero-length directory entries the legacy layout writes, and
        // 308 deflated — four more than the 304 that note claims.
        #expect(stored == 344)
        #expect(deflated == 308)
        #expect(directories == 95)
    }
}

/// Locating the reference library, shared by the zip and import suites. Tests
/// that need it skip when it is absent rather than failing.
enum HighlandCorpus {
    static let root = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Code/github.com/stevemurr/screenplays")

    /// Every `.highland` in the library, in a stable order.
    static var bundles: [URL]? {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var found: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "highland" { found.append(url) }
        }
        return found.isEmpty ? nil : found.sorted { $0.path < $1.path }
    }

    static func bundle(named name: String) -> URL? {
        bundles?.first { $0.lastPathComponent == name }
    }

    /// `The Gig Economy Script.highland` was written back after a lossy UTF-8
    /// round trip: 138 non-ASCII bytes are replaced with U+FFFD, which shifted
    /// every offset in the file. Its central directory no longer sits where the
    /// end-of-central-directory record says. `/usr/bin/unzip` fails on it too.
    static let knownDamaged = ["The Gig Economy Script.highland"]
}
