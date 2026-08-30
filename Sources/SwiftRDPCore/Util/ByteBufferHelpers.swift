import Foundation
import NIOCore

enum Endian {
    case little
    case big
}

extension ByteBuffer {
    mutating func readUInt16(endian: Endian = .little) -> UInt16? {
        guard let v = readInteger(endianness: endian == .little ? .little : .big, as: UInt16.self) else { return nil }
        return v
    }

    mutating func readUInt32(endian: Endian = .little) -> UInt32? {
        guard let v = readInteger(endianness: endian == .little ? .little : .big, as: UInt32.self) else { return nil }
        return v
    }

    mutating func writeUInt16(_ value: UInt16, endian: Endian = .little) {
        writeInteger(value, endianness: endian == .little ? .little : .big)
    }

    mutating func writeUInt32(_ value: UInt32, endian: Endian = .little) {
        writeInteger(value, endianness: endian == .little ? .little : .big)
    }

    mutating func writeUInt8(_ value: UInt8) {
        writeInteger(value)
    }

    mutating func readBytesExact(_ count: Int) -> [UInt8]? {
        guard readableBytes >= count else { return nil }
        return readBytes(length: count)
    }
}

enum ByteWriter {
    static func u16(_ v: UInt16, endian: Endian = .little) -> [UInt8] {
        var le = endian == .little ? v.littleEndian : v.bigEndian
        return withUnsafeBytes(of: &le) { Array($0) }
    }

    static func u32(_ v: UInt32, endian: Endian = .little) -> [UInt8] {
        var le = endian == .little ? v.littleEndian : v.bigEndian
        return withUnsafeBytes(of: &le) { Array($0) }
    }

    static func u64(_ v: UInt64, endian: Endian = .little) -> [UInt8] {
        var le = endian == .little ? v.littleEndian : v.bigEndian
        return withUnsafeBytes(of: &le) { Array($0) }
    }
}

extension Array where Element == UInt8 {
    mutating func appendU16(_ v: UInt16, endian: Endian = .little) {
        append(contentsOf: ByteWriter.u16(v, endian: endian))
    }

    mutating func appendU32(_ v: UInt32, endian: Endian = .little) {
        append(contentsOf: ByteWriter.u32(v, endian: endian))
    }

    mutating func appendU64(_ v: UInt64, endian: Endian = .little) {
        append(contentsOf: ByteWriter.u32(UInt32(v & 0xFFFF_FFFF), endian: endian))
        append(contentsOf: ByteWriter.u32(UInt32(v >> 32), endian: endian))
    }

    mutating func appendU8(_ v: UInt8) {
        append(v)
    }

    func hexPreview(_ max: Int = 64) -> String {
        let slice = prefix(max)
        let s = slice.map { String(format: "%02x", $0) }.joined(separator: " ")
        return count > max ? s + " …" : s
    }
}
