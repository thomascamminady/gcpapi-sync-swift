/// A minimal, dependency-free zip reader for Garmin's activity downloads: it lists the
/// archive's entries from the central directory and extracts stored or deflated ones,
/// verifying their CRC-32.
struct ZipArchive {
    /// One file in the archive.
    struct Entry {
        let name: String
        let method: UInt16
        let crc32: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int

        var isDirectory: Bool { name.hasSuffix("/") }
    }

    /// Why an archive could not be read.
    struct Failure: Error {
        let message: String

        init(_ message: String) {
            self.message = message
        }
    }

    private let bytes: [UInt8]
    let entries: [Entry]

    init(_ bytes: [UInt8]) throws(Failure) {
        self.bytes = bytes
        entries = try Self.centralDirectory(bytes)
    }

    func contents(of entry: Entry) throws(Failure) -> [UInt8] {
        let header = entry.localHeaderOffset
        guard Self.uint32(bytes, header) == 0x0403_4b50 else {
            throw Failure("bad local header for \(entry.name)")
        }
        let start =
            header + 30 + Int(Self.uint16(bytes, header + 26))
            + Int(Self.uint16(bytes, header + 28))
        guard start + entry.compressedSize <= bytes.count else {
            throw Failure("\(entry.name) is truncated")
        }
        let raw = Array(bytes[start..<start + entry.compressedSize])
        let data: [UInt8]
        switch entry.method {
        case 0: data = raw
        case 8: data = try Inflate.decompress(raw, limit: entry.uncompressedSize)
        default: throw Failure("\(entry.name) uses unsupported compression \(entry.method)")
        }
        guard data.count == entry.uncompressedSize, CRC32.checksum(data) == entry.crc32 else {
            throw Failure("\(entry.name) is corrupt")
        }
        return data
    }

    private static func centralDirectory(_ bytes: [UInt8]) throws(Failure) -> [Entry] {
        // The end-of-central-directory record is in the last 22 + 65535 bytes.
        let lowest = max(0, bytes.count - 22 - 65_535)
        var end = bytes.count - 22
        while end >= lowest, uint32(bytes, end) != 0x0605_4b50 {
            end -= 1
        }
        guard end >= lowest else { throw Failure("not a zip archive") }
        let count = Int(uint16(bytes, end + 10))
        var offset = Int(uint32(bytes, end + 16))
        var entries: [Entry] = []
        for _ in 0..<count {
            guard uint32(bytes, offset) == 0x0201_4b50 else {
                throw Failure("bad central directory")
            }
            let nameLength = Int(uint16(bytes, offset + 28))
            let extraLength = Int(uint16(bytes, offset + 30))
            let commentLength = Int(uint16(bytes, offset + 32))
            let nameStart = offset + 46
            guard nameStart + nameLength <= bytes.count else {
                throw Failure("bad central directory")
            }
            entries.append(
                Entry(
                    name: String(
                        decoding: bytes[nameStart..<nameStart + nameLength], as: UTF8.self),
                    method: uint16(bytes, offset + 10),
                    crc32: uint32(bytes, offset + 16),
                    compressedSize: Int(uint32(bytes, offset + 20)),
                    uncompressedSize: Int(uint32(bytes, offset + 24)),
                    localHeaderOffset: Int(uint32(bytes, offset + 42))
                )
            )
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Little-endian integers; out-of-range reads yield 0 (and then fail validation).
    private static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(uint16(bytes, offset)) | UInt32(uint16(bytes, offset + 2)) << 16
    }
}

/// CRC-32 (IEEE 802.3), as used by zip.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xedb8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
        return crc ^ 0xffff_ffff
    }
}

/// A DEFLATE (RFC 1951) decoder for stored, fixed-Huffman and dynamic-Huffman blocks.
enum Inflate {
    private static let lengthBase = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
    ]
    private static let lengthExtra = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ]
    private static let distanceBase = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12_289, 16_385, 24_577,
    ]
    private static let distanceExtra = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    ]
    /// The order in which code-length code lengths are transmitted.
    private static let codeLengthOrder = [
        16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
    ]

    /// A canonical Huffman code: symbol counts per length and symbols in code order.
    private struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int]

        init(lengths: [Int]) throws(ZipArchive.Failure) {
            for length in lengths {
                counts[length] += 1
            }
            counts[0] = 0
            var left = 1
            for length in 1..<16 {
                left = left * 2 - counts[length]
                guard left >= 0 else { throw ZipArchive.Failure("bad Huffman code") }
            }
            var offsets = [Int](repeating: 0, count: 16)
            for length in 1..<15 {
                offsets[length + 1] = offsets[length] + counts[length]
            }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (symbol, length) in lengths.enumerated() where length != 0 {
                symbols[offsets[length]] = symbol
                offsets[length] += 1
            }
        }
    }

    /// Reads bits least-significant first, as DEFLATE requires.
    private struct BitReader {
        let bytes: [UInt8]
        var position = 0
        var buffer = 0
        var available = 0

        mutating func bits(_ count: Int) throws(ZipArchive.Failure) -> Int {
            while available < count {
                guard position < bytes.count else {
                    throw ZipArchive.Failure("compressed data ends early")
                }
                buffer |= Int(bytes[position]) << available
                position += 1
                available += 8
            }
            let value = buffer & ((1 << count) - 1)
            buffer >>= count
            available -= count
            return value
        }

        mutating func decode(_ code: Huffman) throws(ZipArchive.Failure) -> Int {
            var value = 0
            var first = 0
            var index = 0
            for length in 1..<16 {
                value |= try bits(1)
                let count = code.counts[length]
                if value - count < first {
                    return code.symbols[index + value - first]
                }
                index += count
                first = (first + count) << 1
                value <<= 1
            }
            throw ZipArchive.Failure("bad Huffman symbol")
        }

        mutating func alignToByte() {
            buffer = 0
            available = 0
        }
    }

    static func decompress(_ input: [UInt8], limit: Int) throws(ZipArchive.Failure) -> [UInt8] {
        var reader = BitReader(bytes: input)
        var output: [UInt8] = []
        output.reserveCapacity(limit)
        var last = false
        while !last {
            last = try reader.bits(1) == 1
            switch try reader.bits(2) {
            case 0: try stored(&reader, &output)
            case 1:
                let (literals, distances) = try fixedCodes()
                try codes(&reader, &output, literals, distances, limit: limit)
            case 2:
                let (literals, distances) = try dynamicCodes(&reader)
                try codes(&reader, &output, literals, distances, limit: limit)
            default: throw ZipArchive.Failure("bad block type")
            }
            guard output.count <= limit else { throw ZipArchive.Failure("data is too large") }
        }
        return output
    }

    private static func stored(
        _ reader: inout BitReader, _ output: inout [UInt8]
    )
        throws(ZipArchive.Failure)
    {
        reader.alignToByte()
        guard reader.position + 4 <= reader.bytes.count else {
            throw ZipArchive.Failure("compressed data ends early")
        }
        let position = reader.position
        let length = Int(reader.bytes[position]) | Int(reader.bytes[position + 1]) << 8
        let complement = Int(reader.bytes[position + 2]) | Int(reader.bytes[position + 3]) << 8
        guard length == ~complement & 0xffff, position + 4 + length <= reader.bytes.count else {
            throw ZipArchive.Failure("bad stored block")
        }
        output += reader.bytes[position + 4..<position + 4 + length]
        reader.position = position + 4 + length
    }

    private static func fixedCodes() throws(ZipArchive.Failure) -> (Huffman, Huffman) {
        var lengths = [Int](repeating: 8, count: 288)
        for symbol in 144..<256 {
            lengths[symbol] = 9
        }
        for symbol in 256..<280 {
            lengths[symbol] = 7
        }
        return (
            try Huffman(lengths: lengths), try Huffman(lengths: [Int](repeating: 5, count: 30))
        )
    }

    private static func dynamicCodes(
        _ reader: inout BitReader
    ) throws(ZipArchive.Failure)
        -> (Huffman, Huffman)
    {
        let literalCount = try reader.bits(5) + 257
        let distanceCount = try reader.bits(5) + 1
        let codeLengthCount = try reader.bits(4) + 4
        var codeLengthLengths = [Int](repeating: 0, count: 19)
        for index in 0..<codeLengthCount {
            codeLengthLengths[codeLengthOrder[index]] = try reader.bits(3)
        }
        let codeLengths = try Huffman(lengths: codeLengthLengths)
        var lengths: [Int] = []
        while lengths.count < literalCount + distanceCount {
            let symbol = try reader.decode(codeLengths)
            switch symbol {
            case 0..<16: lengths.append(symbol)
            case 16:
                guard let previous = lengths.last else {
                    throw ZipArchive.Failure("repeat without a previous length")
                }
                lengths += [Int](repeating: previous, count: try reader.bits(2) + 3)
            case 17: lengths += [Int](repeating: 0, count: try reader.bits(3) + 3)
            default: lengths += [Int](repeating: 0, count: try reader.bits(7) + 11)
            }
        }
        guard lengths.count == literalCount + distanceCount, lengths[256] != 0 else {
            throw ZipArchive.Failure("bad code lengths")
        }
        return (
            try Huffman(lengths: Array(lengths[..<literalCount])),
            try Huffman(lengths: Array(lengths[literalCount...]))
        )
    }

    private static func codes(
        _ reader: inout BitReader, _ output: inout [UInt8], _ literals: Huffman,
        _ distances: Huffman, limit: Int
    ) throws(ZipArchive.Failure) {
        while true {
            let symbol = try reader.decode(literals)
            if symbol < 256 {
                output.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                let index = symbol - 257
                guard index < lengthBase.count else { throw ZipArchive.Failure("bad length") }
                let length = lengthBase[index] + (try reader.bits(lengthExtra[index]))
                let code = try reader.decode(distances)
                guard code < distanceBase.count else { throw ZipArchive.Failure("bad distance") }
                let distance = distanceBase[code] + (try reader.bits(distanceExtra[code]))
                guard distance <= output.count else {
                    throw ZipArchive.Failure("distance too far back")
                }
                for _ in 0..<length {
                    output.append(output[output.count - distance])
                }
            }
            guard output.count <= limit else { throw ZipArchive.Failure("data is too large") }
        }
    }
}
