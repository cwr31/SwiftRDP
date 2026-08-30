import Foundation

/// RDP 8 bulk compression and RDP_SEGMENTED_DATA framing (MS-RDPEGFX).
public final class ZGFXCompressor {
    public static let segmentedSingle: UInt8 = 0xE0
    public static let segmentedMultipart: UInt8 = 0xE1
    public static let packetComprTypeRDP8: UInt8 = 0x04
    public static let packetCompressed: UInt8 = 0x20
    public static let historyBufferSize = 2_500_000
    public static let maxSegmentUncompressed = 65_535

    private struct Token {
        let prefixLength: Int
        let prefixCode: UInt32
        let valueBits: Int
        let isMatch: Bool
        let valueBase: Int
    }

    // FreeRDP libfreerdp/codec/zgfx.c ZGFX_TOKEN_TABLE.
    private static let tokenTable: [Token] = [
        Token(prefixLength: 1, prefixCode: 0, valueBits: 8, isMatch: false, valueBase: 0),
        Token(prefixLength: 5, prefixCode: 17, valueBits: 5, isMatch: true, valueBase: 0),
        Token(prefixLength: 5, prefixCode: 18, valueBits: 7, isMatch: true, valueBase: 32),
        Token(prefixLength: 5, prefixCode: 19, valueBits: 9, isMatch: true, valueBase: 160),
        Token(prefixLength: 5, prefixCode: 20, valueBits: 10, isMatch: true, valueBase: 672),
        Token(prefixLength: 5, prefixCode: 21, valueBits: 12, isMatch: true, valueBase: 1696),
        Token(prefixLength: 5, prefixCode: 24, valueBits: 0, isMatch: false, valueBase: 0x00),
        Token(prefixLength: 5, prefixCode: 25, valueBits: 0, isMatch: false, valueBase: 0x01),
        Token(prefixLength: 6, prefixCode: 44, valueBits: 14, isMatch: true, valueBase: 5792),
        Token(prefixLength: 6, prefixCode: 45, valueBits: 15, isMatch: true, valueBase: 22176),
        Token(prefixLength: 6, prefixCode: 52, valueBits: 0, isMatch: false, valueBase: 0x02),
        Token(prefixLength: 6, prefixCode: 53, valueBits: 0, isMatch: false, valueBase: 0x03),
        Token(prefixLength: 6, prefixCode: 54, valueBits: 0, isMatch: false, valueBase: 0xFF),
        Token(prefixLength: 7, prefixCode: 92, valueBits: 18, isMatch: true, valueBase: 54944),
        Token(prefixLength: 7, prefixCode: 93, valueBits: 20, isMatch: true, valueBase: 317088),
        Token(prefixLength: 7, prefixCode: 110, valueBits: 0, isMatch: false, valueBase: 0x04),
        Token(prefixLength: 7, prefixCode: 111, valueBits: 0, isMatch: false, valueBase: 0x05),
        Token(prefixLength: 7, prefixCode: 112, valueBits: 0, isMatch: false, valueBase: 0x06),
        Token(prefixLength: 7, prefixCode: 113, valueBits: 0, isMatch: false, valueBase: 0x07),
        Token(prefixLength: 7, prefixCode: 114, valueBits: 0, isMatch: false, valueBase: 0x08),
        Token(prefixLength: 7, prefixCode: 115, valueBits: 0, isMatch: false, valueBase: 0x09),
        Token(prefixLength: 7, prefixCode: 116, valueBits: 0, isMatch: false, valueBase: 0x0A),
        Token(prefixLength: 7, prefixCode: 117, valueBits: 0, isMatch: false, valueBase: 0x0B),
        Token(prefixLength: 7, prefixCode: 118, valueBits: 0, isMatch: false, valueBase: 0x3A),
        Token(prefixLength: 7, prefixCode: 119, valueBits: 0, isMatch: false, valueBase: 0x3B),
        Token(prefixLength: 7, prefixCode: 120, valueBits: 0, isMatch: false, valueBase: 0x3C),
        Token(prefixLength: 7, prefixCode: 121, valueBits: 0, isMatch: false, valueBase: 0x3D),
        Token(prefixLength: 7, prefixCode: 122, valueBits: 0, isMatch: false, valueBase: 0x3E),
        Token(prefixLength: 7, prefixCode: 123, valueBits: 0, isMatch: false, valueBase: 0x3F),
        Token(prefixLength: 7, prefixCode: 124, valueBits: 0, isMatch: false, valueBase: 0x40),
        Token(prefixLength: 7, prefixCode: 125, valueBits: 0, isMatch: false, valueBase: 0x80),
        Token(prefixLength: 8, prefixCode: 188, valueBits: 20, isMatch: true, valueBase: 1365664),
        Token(prefixLength: 8, prefixCode: 189, valueBits: 21, isMatch: true, valueBase: 2414240),
        Token(prefixLength: 8, prefixCode: 252, valueBits: 0, isMatch: false, valueBase: 0x0C),
        Token(prefixLength: 8, prefixCode: 253, valueBits: 0, isMatch: false, valueBase: 0x38),
        Token(prefixLength: 8, prefixCode: 254, valueBits: 0, isMatch: false, valueBase: 0x39),
        Token(prefixLength: 8, prefixCode: 255, valueBits: 0, isMatch: false, valueBase: 0x66),
        Token(prefixLength: 9, prefixCode: 380, valueBits: 22, isMatch: true, valueBase: 4511392),
        Token(prefixLength: 9, prefixCode: 381, valueBits: 23, isMatch: true, valueBase: 8705696),
        Token(prefixLength: 9, prefixCode: 382, valueBits: 24, isMatch: true, valueBase: 17094304),
    ]

    private var history = [UInt8](repeating: 0, count: historyBufferSize)
    private var historyIndex = 0

    public init() {
        RDPLog.gfx.info("GFX: ZGFX RDP8 bulk codec enabled")
    }

    public func reset() {
        historyIndex = 0
    }

    /// Wrap one or more concatenated GFX PDUs in RDP_SEGMENTED_DATA.
    /// - Parameter compress: when false, skip LZ77 and emit uncompressed RDP8
    ///   bulk segments. H.264 access units almost never shrink and the pure-Swift
    ///   compressor dominates post-encode CPU on Retina frames.
    public func wrap(_ data: [UInt8], compress: Bool = true) -> [UInt8] {
        if data.count <= Self.maxSegmentUncompressed {
            return [Self.segmentedSingle] + encodeSegment(data[...], compress: compress)
        }

        let segmentCount = (data.count + Self.maxSegmentUncompressed - 1)
            / Self.maxSegmentUncompressed
        precondition(segmentCount <= Int(UInt16.max), "ZGFX payload has too many segments")
        precondition(data.count <= Int(UInt32.max), "ZGFX payload is too large")

        var output: [UInt8] = [Self.segmentedMultipart]
        output.appendU16(UInt16(segmentCount))
        output.appendU32(UInt32(data.count))

        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.maxSegmentUncompressed, data.count)
            let segment = encodeSegment(data[offset..<end], compress: compress)
            output.appendU32(UInt32(segment.count))
            output.append(contentsOf: segment)
            offset = end
        }
        return output
    }

    /// Decode one RDP 8 bulk segment, including its one-byte compression header.
    public func decompressSegment(_ segment: [UInt8]) -> [UInt8]? {
        guard let flags = segment.first,
              flags & 0x0F == Self.packetComprTypeRDP8 else {
            RDPLog.gfx.error("ZGFX: invalid or missing RDP8 segment header")
            return nil
        }

        if flags & Self.packetCompressed == 0 {
            let output = Array(segment.dropFirst())
            guard output.count <= Self.maxSegmentUncompressed else {
                RDPLog.gfx.error("ZGFX: uncompressed segment exceeds 65535 bytes")
                return nil
            }
            writeHistory(output)
            return output
        }

        guard segment.count >= 3 else {
            RDPLog.gfx.error("ZGFX: compressed segment is truncated")
            return nil
        }
        let encoded = Array(segment.dropFirst().dropLast())
        let padding = Int(segment.last!)
        guard padding <= 7, encoded.count * 8 >= padding else {
            RDPLog.gfx.error("ZGFX: invalid compressed padding")
            return nil
        }

        var reader = BitReader(bytes: encoded, bitCount: encoded.count * 8 - padding)
        var output: [UInt8] = []
        output.reserveCapacity(Self.maxSegmentUncompressed)

        while reader.remaining > 0 {
            guard let token = Self.readToken(from: &reader) else {
                RDPLog.gfx.error("ZGFX: invalid token prefix")
                return nil
            }
            guard let value = reader.read(token.valueBits) else {
                RDPLog.gfx.error("ZGFX: truncated token value")
                return nil
            }

            if !token.isMatch {
                guard output.count < Self.maxSegmentUncompressed else { return nil }
                output.append(UInt8(token.valueBase + Int(value)))
                continue
            }

            let distance = token.valueBase + Int(value)
            if distance == 0 {
                guard let countBits = reader.read(15) else { return nil }
                let count = Int(countBits)
                reader.alignToByte()
                guard output.count + count <= Self.maxSegmentUncompressed,
                      let bytes = reader.readBytes(count) else {
                    return nil
                }
                output.append(contentsOf: bytes)
                continue
            }

            guard distance <= Self.historyBufferSize,
                  let count = Self.readMatchLength(from: &reader),
                  output.count + count <= Self.maxSegmentUncompressed else {
                RDPLog.gfx.error("ZGFX: invalid match distance or length")
                return nil
            }
            for _ in 0..<count {
                let source = output.count - distance
                let byte: UInt8
                if source >= 0 {
                    byte = output[source]
                } else {
                    let index = (historyIndex + Self.historyBufferSize + source)
                        % Self.historyBufferSize
                    byte = history[index]
                }
                output.append(byte)
            }
        }

        writeHistory(output)
        return output
    }

    /// Decode RDP_SEGMENTED_DATA (`E0` single or `E1` multipart).
    public func decompress(_ framed: [UInt8]) -> [UInt8]? {
        guard let descriptor = framed.first else { return nil }
        if descriptor == Self.segmentedSingle {
            return decompressSegment(Array(framed.dropFirst()))
        }
        guard descriptor == Self.segmentedMultipart, framed.count >= 7 else {
            RDPLog.gfx.error("ZGFX: invalid segmented data descriptor")
            return nil
        }

        let segmentCount = Int(Self.readU16(framed, at: 1))
        let expectedSize = Int(Self.readU32(framed, at: 3))
        var offset = 7
        var output: [UInt8] = []
        output.reserveCapacity(expectedSize)
        for _ in 0..<segmentCount {
            guard offset + 4 <= framed.count else { return nil }
            let length = Int(Self.readU32(framed, at: offset))
            offset += 4
            guard length > 0, offset + length <= framed.count,
                  let decoded = decompressSegment(Array(framed[offset..<(offset + length)])) else {
                return nil
            }
            output.append(contentsOf: decoded)
            guard output.count <= expectedSize else { return nil }
            offset += length
        }
        guard offset == framed.count, output.count == expectedSize else {
            RDPLog.gfx.error("ZGFX: multipart size mismatch")
            return nil
        }
        return output
    }

    private func encodeSegment(_ slice: ArraySlice<UInt8>, compress: Bool) -> [UInt8] {
        let data = Array(slice)
        let segment: [UInt8]
        if compress {
            let compressed = Self.compress(data)
            if compressed.count + 1 < data.count + 1 {
                segment = [Self.packetComprTypeRDP8 | Self.packetCompressed] + compressed
            } else {
                segment = [Self.packetComprTypeRDP8] + data
            }
        } else {
            segment = [Self.packetComprTypeRDP8] + data
        }
        writeHistory(data)
        return segment
    }

    /// A bounded hash-chain LZ77 encoder. Matches are within the current segment;
    /// history is still maintained for interoperable decoding in both directions.
    private static func compress(_ data: [UInt8]) -> [UInt8] {
        var writer = BitWriter()
        var positions: [UInt32: [Int]] = [:]
        var offset = 0
        while offset < data.count {
            var bestLength = 0
            var bestDistance = 0
            if offset + 2 < data.count {
                let key = hash(data, at: offset)
                if let candidates = positions[key] {
                    for candidate in candidates.reversed().prefix(16) {
                        let distance = offset - candidate
                        var length = 0
                        while offset + length < data.count,
                              length < Self.maxSegmentUncompressed,
                              data[candidate + (length % distance)] == data[offset + length] {
                            length += 1
                        }
                        if length >= 3, length > bestLength {
                            bestLength = length
                            bestDistance = distance
                        }
                    }
                }
            }

            if bestLength >= 3, let token = matchToken(for: bestDistance) {
                writer.append(token.prefixCode, count: token.prefixLength)
                writer.append(UInt32(bestDistance - token.valueBase), count: token.valueBits)
                appendMatchLength(bestLength, to: &writer)
                let end = min(offset + bestLength, data.count)
                while offset < end {
                    addPosition(data, at: offset, to: &positions)
                    offset += 1
                }
            } else {
                appendLiteral(data[offset], to: &writer)
                addPosition(data, at: offset, to: &positions)
                offset += 1
            }
        }
        let padding = writer.finish()
        return writer.bytes + [UInt8(padding)]
    }

    private static func appendLiteral(_ byte: UInt8, to writer: inout BitWriter) {
        if let token = tokenTable.first(where: {
            !$0.isMatch && $0.valueBits == 0 && $0.valueBase == Int(byte)
        }) {
            writer.append(token.prefixCode, count: token.prefixLength)
        } else {
            writer.append(0, count: 1)
            writer.append(UInt32(byte), count: 8)
        }
    }

    private static func matchToken(for distance: Int) -> Token? {
        tokenTable.first {
            $0.isMatch && distance >= $0.valueBase
                && distance - $0.valueBase < (1 << $0.valueBits)
        }
    }

    private static func appendMatchLength(_ length: Int, to writer: inout BitWriter) {
        if length == 3 {
            writer.append(0, count: 1)
            return
        }
        let exponent = Int.bitWidth - 1 - length.leadingZeroBitCount
        writer.append(1, count: 1)
        if exponent > 2 {
            writer.append((1 << (exponent - 2)) - 1, count: exponent - 2)
        }
        writer.append(0, count: 1)
        writer.append(UInt32(length - (1 << exponent)), count: exponent)
    }

    private static func readToken(from reader: inout BitReader) -> Token? {
        var prefix: UInt32 = 0
        for length in 1...9 {
            guard let bit = reader.read(1) else { return nil }
            prefix = (prefix << 1) | bit
            if let token = tokenTable.first(where: {
                $0.prefixLength == length && $0.prefixCode == prefix
            }) {
                return token
            }
        }
        return nil
    }

    private static func readMatchLength(from reader: inout BitReader) -> Int? {
        guard let first = reader.read(1) else { return nil }
        if first == 0 { return 3 }
        var count = 4
        var extra = 2
        while true {
            guard let continuation = reader.read(1) else { return nil }
            if continuation == 0 { break }
            count *= 2
            extra += 1
        }
        guard let suffix = reader.read(extra) else { return nil }
        return count + Int(suffix)
    }

    private func writeHistory(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let kept = bytes.suffix(Self.historyBufferSize)
        for byte in kept {
            history[historyIndex] = byte
            historyIndex += 1
            if historyIndex == Self.historyBufferSize { historyIndex = 0 }
        }
    }

    private static func hash(_ data: [UInt8], at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 16 | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2])
    }

    private static func addPosition(
        _ data: [UInt8],
        at offset: Int,
        to positions: inout [UInt32: [Int]]
    ) {
        guard offset + 2 < data.count else { return }
        let key = hash(data, at: offset)
        var chain = positions[key, default: []]
        chain.append(offset)
        if chain.count > 16 { chain.removeFirst() }
        positions[key] = chain
    }

    private static func readU16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func readU32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private struct BitReader {
        let bytes: [UInt8]
        let bitCount: Int
        var position = 0

        var remaining: Int { bitCount - position }

        mutating func read(_ count: Int) -> UInt32? {
            guard count >= 0, count <= 32, count <= remaining else { return nil }
            var value: UInt32 = 0
            for _ in 0..<count {
                let byte = bytes[position / 8]
                let bit = (byte >> (7 - position % 8)) & 1
                value = (value << 1) | UInt32(bit)
                position += 1
            }
            return value
        }

        mutating func alignToByte() {
            position = min(bitCount, (position + 7) & ~7)
        }

        mutating func readBytes(_ count: Int) -> [UInt8]? {
            guard position % 8 == 0, count >= 0, count * 8 <= remaining else { return nil }
            let start = position / 8
            position += count * 8
            return Array(bytes[start..<(start + count)])
        }
    }

    private struct BitWriter {
        var bytes: [UInt8] = []
        private var current: UInt8 = 0
        private var used = 0

        mutating func append(_ value: UInt32, count: Int) {
            guard count > 0 else { return }
            for shift in stride(from: count - 1, through: 0, by: -1) {
                current = (current << 1) | UInt8((value >> shift) & 1)
                used += 1
                if used == 8 {
                    bytes.append(current)
                    current = 0
                    used = 0
                }
            }
        }

        mutating func finish() -> Int {
            guard used > 0 else { return 0 }
            let padding = 8 - used
            current <<= padding
            bytes.append(current)
            current = 0
            used = 0
            return padding
        }
    }
}
