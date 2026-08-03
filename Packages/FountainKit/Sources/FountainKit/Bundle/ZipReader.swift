import Compression
import Foundation

/// A read-only zip reader, sufficient for the archive inside a `.highland`.
///
/// It exists so importing a Highland document costs zero external dependencies
/// (see `Package.swift`). The format needed here is small: an End-of-Central-
/// Directory record, a central directory, and per-entry local headers. Only two
/// compression methods appear across the reference library's 59 bundles — 344
/// `Stored` entries and 308 `Deflated` ones — and Apple's `Compression`
/// framework decodes the latter.
///
/// **There is deliberately no writer.** Rule 6: `.highland` is read-only,
/// forever. Nothing in this file opens a file handle at all; callers hand over
/// bytes they have already read.
public struct ZipReader {

    /// One member of the archive, as described by the central directory.
    public struct Entry: Sendable {
        /// The path, decoded leniently — never trust it to be well-formed text.
        public let name: String
        /// The exact filename bytes. `name` is a best-effort rendering of these;
        /// when they are not valid text, only this is authoritative.
        public let nameBytes: [UInt8]
        /// Zip has no directory flag: a directory is a zero-length entry whose
        /// name ends in a slash.
        public let isDirectory: Bool
        public let compressionMethod: UInt16
        public let compressedSize: Int
        public let uncompressedSize: Int
        public let crc32: UInt32
        /// Offset of this entry's local file header from the start of the file.
        let localHeaderOffset: Int
    }

    /// Entries in central-directory order.
    public let entries: [Entry]
    private let bytes: [UInt8]

    // Signatures, little-endian.
    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralHeaderSignature: UInt32 = 0x0201_4b50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4b50
    private static let zip64EndOfCentralDirectorySignature: UInt32 = 0x0606_4b50

    private static let storedMethod: UInt16 = 0
    private static let deflatedMethod: UInt16 = 8

    /// Parses the central directory. Entry payloads are decoded lazily, on
    /// demand, so a bundle carrying a 350 KB screenshot costs nothing to open.
    public init(data: Data) throws {
        // Copied into an array so every offset in this file is measured from
        // zero. `Data` slices carry a non-zero `startIndex`, which is a whole
        // family of off-by-one bugs that simply cannot happen this way.
        self.bytes = [UInt8](data)
        self.entries = try ZipReader.parseCentralDirectory(bytes)
    }

    // MARK: - Lookup

    public subscript(name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    /// The decoded contents of `entry`, verified against its stored CRC-32.
    public func data(for entry: Entry) throws -> Data {
        guard !entry.isDirectory else { return Data() }
        guard entry.uncompressedSize > 0 else { return Data() }

        let start = try payloadStart(of: entry)
        guard start >= 0, start + entry.compressedSize <= bytes.count else {
            throw ZipError.truncatedEntry(entry.name)
        }
        let compressed = bytes[start..<(start + entry.compressedSize)]

        let output: Data
        switch entry.compressionMethod {
        case ZipReader.storedMethod:
            guard entry.compressedSize == entry.uncompressedSize else {
                throw ZipError.corruptEntry(entry.name)
            }
            output = Data(compressed)
        case ZipReader.deflatedMethod:
            output = try ZipReader.inflate(compressed, to: entry.uncompressedSize, name: entry.name)
        default:
            throw ZipError.unsupportedCompressionMethod(entry.compressionMethod, entry.name)
        }

        guard ZipReader.crc32(output) == entry.crc32 else {
            throw ZipError.checksumMismatch(entry.name)
        }
        return output
    }

    /// The local header repeats the name and extra-field lengths, and they may
    /// differ from the central directory's, so the payload offset has to be
    /// read from the header itself rather than assumed.
    private func payloadStart(of entry: Entry) throws -> Int {
        let header = entry.localHeaderOffset
        guard header >= 0, header + 30 <= bytes.count,
              ZipReader.read32(bytes, header) == ZipReader.localHeaderSignature else {
            throw ZipError.corruptEntry(entry.name)
        }
        let nameLength = Int(ZipReader.read16(bytes, header + 26))
        let extraLength = Int(ZipReader.read16(bytes, header + 28))
        return header + 30 + nameLength + extraLength
    }

    // MARK: - Central directory

    private static func parseCentralDirectory(_ bytes: [UInt8]) throws -> [Entry] {
        guard let eocd = findEndOfCentralDirectory(bytes) else { throw ZipError.notAZipArchive }

        var count = Int(read16(bytes, eocd + 10))
        var directorySize = Int(read32(bytes, eocd + 12))
        var directoryOffset = Int(read32(bytes, eocd + 16))

        // Zip64. None of the reference library needs it — no bundle is anywhere
        // near 4 GB or 65,535 members — but the sentinel values are unambiguous
        // and honouring them is cheaper than misreading them silently.
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            let locator = eocd - 20
            guard locator >= 0, read32(bytes, locator) == zip64LocatorSignature,
                  let record = within(read64(bytes, locator + 8), bytes),
                  record + 56 <= bytes.count,
                  read32(bytes, record) == zip64EndOfCentralDirectorySignature,
                  let entryCount = within(read64(bytes, record + 32), bytes),
                  let size = within(read64(bytes, record + 40), bytes),
                  let offset = within(read64(bytes, record + 48), bytes) else {
                throw ZipError.zip64Unsupported
            }
            count = entryCount
            directorySize = size
            directoryOffset = offset
        }

        // Archives are sometimes prefixed with unrelated bytes (a self-extracting
        // stub, a botched concatenation). Every recorded offset is then short by
        // the same amount, which the directory's own position gives away. Only
        // trust that arithmetic if it actually lands on a central header —
        // otherwise the recorded offset was right and the sizes were not.
        var delta = eocd - directorySize - directoryOffset
        if delta != 0, read32(bytes, directoryOffset + delta) != centralHeaderSignature,
           read32(bytes, directoryOffset) == centralHeaderSignature {
            delta = 0
        }
        directoryOffset += delta

        guard directoryOffset >= 0, directoryOffset <= bytes.count else {
            throw ZipError.notAZipArchive
        }

        // A central directory record is 46 bytes at minimum, so a count that
        // could not fit came from a damaged header. Checked before reserving,
        // so a garbage number cannot turn into a garbage allocation.
        guard count >= 0, count * 46 <= bytes.count else {
            throw ZipError.corruptCentralDirectory
        }

        var entries: [Entry] = []
        entries.reserveCapacity(count)
        var cursor = directoryOffset

        for _ in 0..<count {
            guard cursor + 46 <= bytes.count,
                  read32(bytes, cursor) == centralHeaderSignature else {
                throw ZipError.corruptCentralDirectory
            }
            let method = read16(bytes, cursor + 10)
            let crc = read32(bytes, cursor + 16)
            var compressed = Int(read32(bytes, cursor + 20))
            var uncompressed = Int(read32(bytes, cursor + 24))
            let nameLength = Int(read16(bytes, cursor + 28))
            let extraLength = Int(read16(bytes, cursor + 30))
            let commentLength = Int(read16(bytes, cursor + 32))
            var localOffset = Int(read32(bytes, cursor + 42))

            let nameStart = cursor + 46
            let extraStart = nameStart + nameLength
            let end = extraStart + extraLength + commentLength
            guard end <= bytes.count else { throw ZipError.corruptCentralDirectory }

            readZip64Extra(
                bytes[extraStart..<(extraStart + extraLength)],
                uncompressed: &uncompressed,
                compressed: &compressed,
                localOffset: &localOffset
            )

            let nameBytes = Array(bytes[nameStart..<extraStart])
            let name = decodeName(nameBytes)
            entries.append(
                Entry(
                    name: name,
                    nameBytes: nameBytes,
                    isDirectory: nameBytes.last == UInt8(ascii: "/"),
                    compressionMethod: method,
                    compressedSize: compressed,
                    uncompressedSize: uncompressed,
                    crc32: crc,
                    localHeaderOffset: localOffset + delta
                )
            )
            cursor = end
        }
        return entries
    }

    /// The zip64 extra field carries replacements, in a fixed order, for exactly
    /// those 32-bit fields that were written as `0xFFFFFFFF`.
    private static func readZip64Extra(
        _ extra: ArraySlice<UInt8>,
        uncompressed: inout Int,
        compressed: inout Int,
        localOffset: inout Int
    ) {
        guard uncompressed == 0xFFFF_FFFF || compressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF
        else { return }

        let fields = Array(extra)
        var cursor = 0
        while cursor + 4 <= fields.count {
            let id = read16(fields, cursor)
            let size = Int(read16(fields, cursor + 2))
            let body = cursor + 4
            guard body + size <= fields.count else { return }
            if id == 0x0001 {
                var field = body
                if uncompressed == 0xFFFF_FFFF, field + 8 <= body + size {
                    uncompressed = clamped(read64(fields, field)); field += 8
                }
                if compressed == 0xFFFF_FFFF, field + 8 <= body + size {
                    compressed = clamped(read64(fields, field)); field += 8
                }
                if localOffset == 0xFFFF_FFFF, field + 8 <= body + size {
                    localOffset = clamped(read64(fields, field))
                }
                return
            }
            cursor = body + size
        }
    }

    /// Scans backwards for the End-of-Central-Directory record. It is last in
    /// the file except for an optional comment, which is at most 64 KB.
    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let limit = max(0, bytes.count - 22 - 0xFFFF)
        var offset = bytes.count - 22
        while offset >= limit {
            if read32(bytes, offset) == endOfCentralDirectorySignature {
                let commentLength = Int(read16(bytes, offset + 20))
                if offset + 22 + commentLength <= bytes.count { return offset }
            }
            offset -= 1
        }
        return nil
    }

    // MARK: - Names

    /// Zip stores filenames as bytes, with a flag that is supposed to say
    /// whether they are UTF-8. In this corpus that flag is unreliable: all 308
    /// deflated entries leave it clear while still storing UTF-8, and two PNG
    /// assets carry names that were already mojibake before Highland saved them.
    /// So: try UTF-8, then Windows-1252, then a replacing decode that cannot
    /// fail. A name we cannot read is never a reason to refuse the archive —
    /// the payload we actually want may be three entries further on.
    static func decodeName(_ bytes: [UInt8]) -> String {
        let data = Data(bytes)
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let latin = String(data: data, encoding: .windowsCP1252) { return latin }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Inflate

    /// `COMPRESSION_ZLIB` is Apple's name for raw DEFLATE (RFC 1951) with no
    /// zlib wrapper (RFC 1950) — which, confusingly, is exactly what zip stores.
    private static func inflate(
        _ source: ArraySlice<UInt8>,
        to size: Int,
        name: String
    ) throws -> Data {
        var output = Data(count: size)
        let produced: Int = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return source.withUnsafeBufferPointer { input -> Int in
                guard let sourceBase = input.baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationBase, size,
                    sourceBase, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard produced == size else { throw ZipError.corruptEntry(name) }
        return output
    }

    // MARK: - CRC-32

    /// Verifying the checksum is what makes "it decoded" mean "it decoded
    /// correctly". `compression_decode_buffer` reports a byte count and nothing
    /// else, so without this a truncated deflate stream of exactly the right
    /// length would read as success.
    private static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        let table = crcTable
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: - Little-endian reads

    /// A 64-bit field read out of a damaged archive can hold anything, and
    /// `Int(_:)` **traps** above `Int.max` — an uncatchable crash on a file the
    /// user merely tried to open. Nothing inside a file can legitimately be
    /// larger than the file.
    private static func within(_ value: UInt64, _ bytes: [UInt8]) -> Int? {
        value <= UInt64(bytes.count) ? Int(value) : nil
    }

    private static func clamped(_ value: UInt64) -> Int {
        Int(truncatingIfNeeded: min(value, UInt64(Int.max)))
    }

    private static func read16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func read64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= bytes.count else { return 0 }
        var value: UInt64 = 0
        for index in (0..<8).reversed() {
            value = (value << 8) | UInt64(bytes[offset + index])
        }
        return value
    }
}

public enum ZipError: LocalizedError, Equatable {
    case notAZipArchive
    case corruptCentralDirectory
    case corruptEntry(String)
    case truncatedEntry(String)
    case checksumMismatch(String)
    case unsupportedCompressionMethod(UInt16, String)
    case zip64Unsupported

    public var errorDescription: String? {
        switch self {
        case .notAZipArchive:
            return "That file isn’t a zip archive — no end-of-central-directory record."
        case .corruptCentralDirectory:
            return "That archive’s table of contents is damaged."
        case .corruptEntry(let name):
            return "“\(name)” inside that archive is damaged."
        case .truncatedEntry(let name):
            return "“\(name)” runs past the end of that archive."
        case .checksumMismatch(let name):
            return "“\(name)” failed its checksum — the archive is damaged."
        case .unsupportedCompressionMethod(let method, let name):
            return "“\(name)” uses compression method \(method), which isn’t supported."
        case .zip64Unsupported:
            return "That archive claims to be zip64 but has no zip64 record."
        }
    }
}
