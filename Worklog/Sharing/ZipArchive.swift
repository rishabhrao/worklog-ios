import Compression
import Foundation

/// A small, flat zip reader and writer.
///
/// The macOS build shells out to `/usr/bin/ditto` and `/usr/bin/unzip`. iOS
/// has no `Process` at all, and pulling in a zip library would break this
/// project's zero-third-party-dependency rule - the same rule that produced a
/// hand-rolled SQLite wrapper rather than an ORM. So this is the format,
/// written out: local headers, a central directory, an end record, DEFLATE via
/// Apple's own Compression framework, and a CRC table.
///
/// Deliberately limited to what the clip-archive format actually is:
///
/// - **Flat.** Every entry is a bare file name with no directory component.
///   Reading enforces that by taking only the last path component of each
///   entry name, which kills zip-slip outright rather than defending against
///   it - the same property `unzip -j` gave the macOS build.
/// - **Store or deflate.** The two methods any zip tool produces for this kind
///   of content. Anything else is refused rather than silently mis-read.
/// - **No zip64.** A clip archive is one audio file and some text.
enum ZipArchive {

    enum ZipError: LocalizedError {
        case malformed(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let detail): return "This zip is damaged: \(detail)."
            case .unsupported(let detail): return "This zip uses \(detail), which Worklog can't read."
            }
        }
    }

    // MARK: - Writing

    /// Zips the *contents* of `folder` as top-level entries - the flat layout
    /// the clip-archive format requires, and what `ditto -c -k` produced on
    /// macOS. Subfolders are ignored; the format has none.
    static func zip(contentsOf folder: URL, to destination: URL) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()

        var payload = Data()
        var central = Data()
        var count = 0

        for name in names {
            let fileURL = folder.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }

            let raw = try Data(contentsOf: fileURL)
            let crc = crc32(raw)
            // Audio is already compressed; deflating it again costs time and
            // saves nothing, and can even grow the entry. Store whatever does
            // not shrink.
            let deflated = raw.isEmpty ? Data() : deflate(raw)
            let useDeflate = !deflated.isEmpty && deflated.count < raw.count
            let stored = useDeflate ? deflated : raw
            let method: UInt16 = useDeflate ? 8 : 0

            let nameBytes = Array(name.utf8)
            let offset = UInt32(payload.count)

            payload.append(uint32: 0x0403_4b50)
            payload.append(uint16: 20)
            payload.append(uint16: 0)
            payload.append(uint16: method)
            payload.append(uint16: 0) // time - archives are content-addressed by the manifest, not by mtime
            payload.append(uint16: 0) // date
            payload.append(uint32: crc)
            payload.append(uint32: UInt32(stored.count))
            payload.append(uint32: UInt32(raw.count))
            payload.append(uint16: UInt16(nameBytes.count))
            payload.append(uint16: 0)
            payload.append(contentsOf: nameBytes)
            payload.append(stored)

            central.append(uint32: 0x0201_4b50)
            central.append(uint16: 20)
            central.append(uint16: 20)
            central.append(uint16: 0)
            central.append(uint16: method)
            central.append(uint16: 0)
            central.append(uint16: 0)
            central.append(uint32: crc)
            central.append(uint32: UInt32(stored.count))
            central.append(uint32: UInt32(raw.count))
            central.append(uint16: UInt16(nameBytes.count))
            central.append(uint16: 0)
            central.append(uint16: 0)
            central.append(uint16: 0)
            central.append(uint16: 0)
            central.append(uint32: 0)
            central.append(uint32: offset)
            central.append(contentsOf: nameBytes)

            count += 1
        }

        var out = payload
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.append(uint32: 0x0605_4b50)
        out.append(uint16: 0)
        out.append(uint16: 0)
        out.append(uint16: UInt16(count))
        out.append(uint16: UInt16(count))
        out.append(uint32: UInt32(central.count))
        out.append(uint32: centralOffset)
        out.append(uint16: 0)

        try out.write(to: destination, options: .atomic)
    }

    // MARK: - Reading

    /// Extracts every entry into `destination` as a bare file name.
    ///
    /// Entry names are reduced to their last path component, so an archive
    /// containing `../../etc/thing` writes `thing` inside the destination and
    /// nothing else - zip-slip is impossible by construction rather than by a
    /// check that could be got around.
    static func unzipFlat(at url: URL, to destination: URL) throws {
        let data = try Data(contentsOf: url)
        guard let eocd = locateEndOfCentralDirectory(in: data) else {
            throw ZipError.malformed("no end-of-central-directory record")
        }

        let entryCount = Int(data.uint16(at: eocd + 10))
        var offset = Int(data.uint32(at: eocd + 16))

        for _ in 0..<entryCount {
            guard offset + 46 <= data.count, data.uint32(at: offset) == 0x0201_4b50 else {
                throw ZipError.malformed("bad central directory entry")
            }
            let method = data.uint16(at: offset + 10)
            let compressedSize = Int(data.uint32(at: offset + 20))
            let uncompressedSize = Int(data.uint32(at: offset + 24))
            let nameLength = Int(data.uint16(at: offset + 28))
            let extraLength = Int(data.uint16(at: offset + 30))
            let commentLength = Int(data.uint16(at: offset + 32))
            let localOffset = Int(data.uint32(at: offset + 42))

            guard offset + 46 + nameLength <= data.count else {
                throw ZipError.malformed("truncated entry name")
            }
            let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
            let rawName = String(decoding: nameData, as: UTF8.self)
            offset += 46 + nameLength + extraLength + commentLength

            // Directory entries carry a trailing slash and no content.
            guard !rawName.hasSuffix("/") else { continue }
            let name = (rawName as NSString).lastPathComponent
            guard !name.isEmpty, name != ".", name != ".." else { continue }

            guard localOffset + 30 <= data.count, data.uint32(at: localOffset) == 0x0403_4b50 else {
                throw ZipError.malformed("bad local header")
            }
            let localNameLength = Int(data.uint16(at: localOffset + 26))
            let localExtraLength = Int(data.uint16(at: localOffset + 28))
            let start = localOffset + 30 + localNameLength + localExtraLength
            guard start + compressedSize <= data.count else {
                throw ZipError.malformed("entry runs past the end of the file")
            }
            let payload = data.subdata(in: start..<(start + compressedSize))

            let contents: Data
            switch method {
            case 0:
                contents = payload
            case 8:
                guard let inflated = inflate(payload, expectedSize: uncompressedSize) else {
                    throw ZipError.malformed("entry \u{201c}\(name)\u{201d} wouldn't decompress")
                }
                contents = inflated
            default:
                throw ZipError.unsupported("compression method \(method)")
            }

            try contents.write(to: destination.appendingPathComponent(name), options: .atomic)
        }
    }

    /// The end record sits at the very end unless there is a trailing comment,
    /// so scan backwards over the largest comment the format allows.
    private static func locateEndOfCentralDirectory(in data: Data) -> Int? {
        let minimum = 22
        guard data.count >= minimum else { return nil }
        let earliest = max(0, data.count - minimum - 0xFFFF)
        var index = data.count - minimum
        while index >= earliest {
            if data.uint32(at: index) == 0x0605_4b50 { return index }
            index -= 1
        }
        return nil
    }

    // MARK: - DEFLATE

    private static func deflate(_ input: Data) -> Data {
        transform(input, operation: COMPRESSION_STREAM_ENCODE, destinationCapacity: input.count + 64) ?? Data()
    }

    private static func inflate(_ input: Data, expectedSize: Int) -> Data? {
        // The header states the uncompressed size, so there is no need to
        // grow a buffer; +1 keeps a zero-length entry from asking for a
        // zero-byte allocation.
        transform(input, operation: COMPRESSION_STREAM_DECODE, destinationCapacity: max(1, expectedSize))
    }

    /// `COMPRESSION_ZLIB` in Apple's API is raw DEFLATE - no zlib wrapper -
    /// which is exactly what a zip entry stores.
    private static func transform(_ input: Data, operation: compression_stream_operation, destinationCapacity: Int) -> Data? {
        guard !input.isEmpty else { return Data() }
        var output = Data(count: destinationCapacity)
        let written: Int = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return input.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                if operation == COMPRESSION_STREAM_ENCODE {
                    return compression_encode_buffer(destinationBase, destinationCapacity, sourceBase, input.count, nil, COMPRESSION_ZLIB)
                }
                return compression_decode_buffer(destinationBase, destinationCapacity, sourceBase, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }

    // MARK: - CRC32

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    mutating func append(uint32 value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }

    func uint16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | (UInt16(self[startIndex + offset + 1]) << 8)
    }

    func uint32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[startIndex + offset])
            | (UInt32(self[startIndex + offset + 1]) << 8)
            | (UInt32(self[startIndex + offset + 2]) << 16)
            | (UInt32(self[startIndex + offset + 3]) << 24)
    }
}
