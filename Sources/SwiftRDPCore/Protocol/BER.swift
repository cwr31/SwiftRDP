import Foundation

/// Minimal BER helpers for MCS / GCC (enough for RDP server path).
enum BER {
    static let tagBoolean: UInt8 = 0x01
    static let tagInteger: UInt8 = 0x02
    static let tagOctetString: UInt8 = 0x04
    static let tagEnum: UInt8 = 0x0A
    static let tagSequence: UInt8 = 0x30
    static let tagSequenceOf: UInt8 = 0x30
    static let tagSetOf: UInt8 = 0x31

    static func encodeLength(_ length: Int) -> [UInt8] {
        if length < 0x80 {
            return [UInt8(length)]
        }
        if length <= 0xFF {
            return [0x81, UInt8(length)]
        }
        if length <= 0xFFFF {
            return [0x82, UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
        }
        return [
            0x83,
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF),
        ]
    }

    static func decodeLength(_ data: [UInt8], offset: inout Int) -> Int? {
        guard offset < data.count else { return nil }
        let first = data[offset]
        offset += 1
        if first & 0x80 == 0 {
            return Int(first)
        }
        let n = Int(first & 0x7F)
        guard n > 0, offset + n <= data.count else { return nil }
        var len = 0
        for _ in 0..<n {
            len = (len << 8) | Int(data[offset])
            offset += 1
        }
        return len
    }

    static func encodeInteger(_ value: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        let v = value
        if v == 0 {
            bytes = [0]
        } else {
            var tmp: [UInt8] = []
            var x = UInt64(bitPattern: Int64(v))
            // two's complement minimal
            if v >= 0 {
                while x > 0 {
                    tmp.insert(UInt8(x & 0xFF), at: 0)
                    x >>= 8
                }
                if let first = tmp.first, first & 0x80 != 0 {
                    tmp.insert(0, at: 0)
                }
            } else {
                // negative — emit at least one byte
                var xv = Int64(v)
                repeat {
                    tmp.insert(UInt8(truncatingIfNeeded: xv), at: 0)
                    xv >>= 8
                } while xv != -1 && xv != 0 || (tmp.first ?? 0) & 0x80 == 0
            }
            bytes = tmp.isEmpty ? [0] : tmp
        }
        return [tagInteger] + encodeLength(bytes.count) + bytes
    }

    static func encodeOctetString(_ data: [UInt8]) -> [UInt8] {
        [tagOctetString] + encodeLength(data.count) + data
    }

    static func encodeEnumeration(_ value: UInt8) -> [UInt8] {
        [tagEnum, 0x01, value]
    }

    static func encodeSequence(_ contents: [UInt8]) -> [UInt8] {
        [tagSequence] + encodeLength(contents.count) + contents
    }

    static func encodeTagged(_ tagNumber: UInt8, constructed: Bool, contents: [UInt8]) -> [UInt8] {
        // Context-specific: class 10, constructed bit
        let t: UInt8 = 0x80 | (constructed ? 0x20 : 0x00) | (tagNumber & 0x1F)
        return [t] + encodeLength(contents.count) + contents
    }

    static func encodeContext(_ tagNumber: UInt8, contents: [UInt8], constructed: Bool = true) -> [UInt8] {
        let t: UInt8 = 0x80 | (constructed ? 0x20 : 0x00) | (tagNumber & 0x1F)
        return [t] + encodeLength(contents.count) + contents
    }
}
