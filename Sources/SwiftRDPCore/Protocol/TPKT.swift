import Foundation

/// ISO TPKT header (MS-RDPBCGR).
public enum TPKT {
    public static let version: UInt8 = 3

    public static func wrap(_ payload: [UInt8]) -> [UInt8] {
        let total = 4 + payload.count
        precondition(total <= 0xFFFF)
        var out: [UInt8] = []
        out.reserveCapacity(total)
        out.append(version)
        out.append(0)
        out.appendU16(UInt16(total), endian: .big)
        out.append(contentsOf: payload)
        return out
    }

    /// Returns payload after TPKT header, or nil if incomplete.
    public static func unwrap(from buffer: inout [UInt8]) -> [UInt8]? {
        guard buffer.count >= 4 else { return nil }
        guard buffer[0] == version else {
            // Not TPKT — may be fast-path later
            return nil
        }
        let length = Int(buffer[2]) << 8 | Int(buffer[3])
        guard length >= 4, buffer.count >= length else { return nil }
        let payload = Array(buffer[4..<length])
        buffer.removeFirst(length)
        return payload
    }

    public static func peekLength(_ buffer: [UInt8]) -> Int? {
        guard buffer.count >= 4, buffer[0] == version else { return nil }
        return Int(buffer[2]) << 8 | Int(buffer[3])
    }
}
