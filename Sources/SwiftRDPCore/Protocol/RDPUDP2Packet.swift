import CryptoKit
import Foundation
import NIOCore

enum RDPUDPError: Error {
    case malformedPacket, bufferOverflow, timedOut, unauthenticatedTunnel, tunnelClosed
}

/// Only the MS-RDPEUDP v3 initialization is used; the data phase is MS-RDPEUDP2.
struct RDPUDPSyn {
    enum ParseError: Error, CustomStringConvertible {
        case truncated
        case header(window: UInt16, flags: UInt16)
        case mtu(upstream: UInt16, downstream: UInt16, bytes: Int)
        case version(flags: UInt16, version: UInt16)

        var description: String {
            switch self {
            case .truncated: return "truncated SYN"
            case .header(let window, let flags):
                return "invalid SYN header window=\(window) flags=0x\(String(flags, radix: 16))"
            case .mtu(let up, let down, let bytes):
                return "invalid SYN MTU up=\(up) down=\(down) bytes=\(bytes)"
            case .version(let flags, let version):
                return "unsupported SYN extension flags=0x\(String(flags, radix: 16)) version=0x\(String(version, radix: 16))"
            }
        }
    }
    let initialSequence: UInt32
    let upstreamMTU: UInt16
    let downstreamMTU: UInt16
    let cookieHash: [UInt8]

    /// MS-RDPEUDP 2.2.2.9 encodes the digest as eight DWORDs in network byte order.
    static func encodeCookieHash(_ cookie: [UInt8]) -> [UInt8] {
        precondition(cookie.count == 16)
        let digest = Array(SHA256.hash(data: Data(cookie)))
        return stride(from: 0, to: digest.count, by: 4).flatMap {
            digest[$0..<($0 + 4)].reversed()
        }
    }

    static func parse(_ bytes: [UInt8]) throws -> RDPUDPSyn {
        var b = ByteBuffer(bytes: bytes)
        guard let ack = b.readInteger(endianness: .big, as: UInt32.self),
              let window = b.readInteger(endianness: .big, as: UInt16.self),
              let flags = b.readInteger(endianness: .big, as: UInt16.self),
              let initial = b.readInteger(endianness: .big, as: UInt32.self),
              let up = b.readInteger(endianness: .big, as: UInt16.self),
              let down = b.readInteger(endianness: .big, as: UInt16.self)
        else { throw ParseError.truncated }
        guard ack == UInt32.max, window > 0,
              flags & ~UInt16(0x1801) == 0, flags & 0x1001 == 0x1001 else {
            throw ParseError.header(window: window, flags: flags)
        }
        guard (1132...1232).contains(up), (1132...1232).contains(down),
              bytes.count == Int(min(up, down)) else {
            throw ParseError.mtu(upstream: up, downstream: down, bytes: bytes.count)
        }
        if flags & 0x0800 != 0 {
            guard b.readableBytes >= 32 else { throw ParseError.truncated }
            b.moveReaderIndex(forwardBy: 32) // optional correlation ID and reserved bytes
        }
        guard let extensionFlags = b.readInteger(endianness: .big, as: UInt16.self),
              let version = b.readInteger(endianness: .big, as: UInt16.self) else { throw ParseError.truncated }
        guard extensionFlags == 1, version == 0x0101 else {
            throw ParseError.version(flags: extensionFlags, version: version)
        }
        guard let hash = b.readBytes(length: 32) else { throw ParseError.truncated }
        return RDPUDPSyn(initialSequence: initial,
                         upstreamMTU: up, downstreamMTU: down, cookieHash: hash)
    }

    func acknowledgement(serverSequence: UInt32, receiveWindow: UInt16) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.appendU32(initialSequence, endian: .big)
        bytes.appendU16(receiveWindow, endian: .big)
        bytes.appendU16(0x1005, endian: .big) // SYN | ACK | SYNEX
        bytes.appendU32(serverSequence, endian: .big)
        let mtu = min(upstreamMTU, downstreamMTU)
        bytes.appendU16(mtu, endian: .big)
        bytes.appendU16(mtu, endian: .big)
        bytes.appendU16(1, endian: .big)
        bytes.appendU16(0x0101, endian: .big)
        // The cookieHash occurs only in the client SYN, never in SYN+ACK.
        bytes += repeatElement(0, count: Int(min(upstreamMTU, downstreamMTU)) - bytes.count)
        return bytes
    }
}

/// MS-RDPEUDP2 2.2.1: optional payloads occur in exactly this wire order.
struct RDPUDP2Packet {
    enum ParseError: Error, CustomStringConvertible {
        case length(Int)
        case prefix(UInt8)
        case flags(UInt16)
        case truncated(field: String, offset: Int)
        case ackVector(size: UInt8)
        case trailingBytes(Int)

        var description: String {
            switch self {
            case .length(let count): return "invalid datagram length=\(count)"
            case .prefix(let value): return "invalid prefix=0x\(String(value, radix: 16))"
            case .flags(let value): return "invalid header=0x\(String(value, radix: 16))"
            case .truncated(let field, let offset): return "truncated \(field) at offset=\(offset)"
            case .ackVector(let size): return "invalid ACK vector size=\(size & 0x7F)"
            case .trailingBytes(let count): return "unexpected trailing bytes=\(count)"
            }
        }
    }

    struct Ack {
        let sequence: UInt16
        let timestamp: UInt32 // 24 bits, in units of 4µs on the peer's clock
        let delayMilliseconds: UInt8
        var timeScale: UInt8 = 0
        var additions: [UInt8] = []
    }
    struct AckVector {
        let base: UInt16
        let timestamp: UInt32?
        let delayMilliseconds: UInt8
        let coded: [UInt8]

        var states: [Bool] {
            coded.flatMap { byte in
                if byte & 0x80 != 0 {
                    return [Bool](repeating: byte & 0x40 != 0, count: Int(byte & 0x3F))
                }
                return (0..<7).map { byte & (1 << $0) != 0 }
            }
        }
    }
    struct DataPayload {
        let sequence: UInt16
        let channelSequence: UInt16?
        let bytes: [UInt8]
    }
    struct DelayAck {
        let count: UInt8
        let milliseconds: UInt16
    }

    var logWindow: UInt8 = 10
    var dummy = false
    var ack: Ack?
    var overhead: UInt8?
    var delayAck: DelayAck?
    var ackOfAcks: UInt16?
    var data: DataPayload?
    var vector: AckVector?

    func encode() -> [UInt8] {
        precondition(logWindow <= 15 && (ack == nil || vector == nil))
        let flags: UInt16 = (ack == nil ? 0 : 1) | (data == nil ? 0 : 4)
            | (vector == nil ? 0 : 8) | (ackOfAcks == nil ? 0 : 0x10)
            | (overhead == nil ? 0 : 0x40) | (delayAck == nil ? 0 : 0x100)
        var bytes: [UInt8] = []
        bytes.appendU16(flags | UInt16(logWindow) << 12)
        func u24(_ value: UInt32) -> [UInt8] {
            [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
             UInt8(truncatingIfNeeded: value >> 16)]
        }
        if let ack {
            precondition(ack.additions.count <= 15 && ack.timeScale <= 15)
            bytes.appendU16(ack.sequence)
            bytes += u24(ack.timestamp)
            bytes.append(ack.delayMilliseconds)
            bytes.append(ack.timeScale << 4 | UInt8(ack.additions.count))
            bytes += ack.additions
        }
        if let overhead { bytes.append(overhead) }
        if let delayAck {
            bytes.append(delayAck.count)
            bytes.appendU16(delayAck.milliseconds)
        }
        if let ackOfAcks { bytes.appendU16(ackOfAcks) }
        if let data { bytes.appendU16(data.sequence) }
        if let vector {
            precondition(vector.coded.count <= 127)
            bytes.appendU16(vector.base)
            bytes.append(UInt8(vector.coded.count) | (vector.timestamp == nil ? 0 : 0x80))
            if let timestamp = vector.timestamp {
                bytes += u24(timestamp)
                bytes.append(vector.delayMilliseconds)
            }
            bytes += vector.coded
        }
        if let data {
            // DATA always includes a DataBody header, even when a dummy's body is ignored.
            bytes.appendU16(data.channelSequence ?? 0)
            if !dummy { bytes += data.bytes }
        }
        let prefix = UInt8(min(bytes.count, 7)) << 5 | (dummy ? 0x10 : 0)
        bytes += repeatElement(0, count: max(0, 7 - bytes.count))
        bytes.insert(prefix, at: 0)
        bytes.swapAt(0, 7)
        return bytes
    }

    static func parse(_ wire: [UInt8]) throws -> RDPUDP2Packet {
        guard (8...1232).contains(wire.count) else { throw ParseError.length(wire.count) }
        var bytes = wire
        bytes.swapAt(0, 7)
        let prefix = bytes.removeFirst()
        let type = (prefix >> 1) & 15, shortLength = Int(prefix >> 5)
        guard prefix & 1 == 0, type == 0 || type == 8 else { throw ParseError.prefix(prefix) }
        if shortLength > 0 && shortLength < 7 {
            guard wire.count == 8 else { throw ParseError.prefix(prefix) }
            bytes.removeLast(7 - shortLength)
        }
        var b = ByteBuffer(bytes: bytes)
        guard let header = b.readInteger(endianness: .little, as: UInt16.self) else {
            throw ParseError.truncated(field: "header", offset: b.readerIndex)
        }
        let flags = header & 0xFFF
        // mstsc sets the undocumented 0x200 bit without adding a payload field.
        // Decode the documented payload flags; TLS still validates the resulting stream.
        guard flags & 0x15D != 0, flags & 9 != 9 else { throw ParseError.flags(header) }
        var packet = RDPUDP2Packet(logWindow: UInt8(header >> 12), dummy: type == 8)
        func u8(_ field: String) throws -> UInt8 {
            guard let v = b.readInteger(as: UInt8.self) else { throw ParseError.truncated(field: field, offset: b.readerIndex) }; return v
        }
        func u16(_ field: String) throws -> UInt16 {
            guard let v = b.readInteger(endianness: .little, as: UInt16.self) else { throw ParseError.truncated(field: field, offset: b.readerIndex) }; return v
        }
        func u24(_ field: String) throws -> UInt32 {
            let lo = try u16(field), hi = try u8(field); return UInt32(lo) | UInt32(hi) << 16
        }
        if flags & 1 != 0 {
            let sequence = try u16("ACK sequence"), timestamp = try u24("ACK timestamp")
            let delay = try u8("ACK delay"), extra = try u8("ACK additions count")
            guard let additions = b.readBytes(length: Int(extra & 15)) else {
                throw ParseError.truncated(field: "ACK additions", offset: b.readerIndex)
            }
            packet.ack = Ack(sequence: sequence, timestamp: timestamp, delayMilliseconds: delay,
                             timeScale: extra >> 4, additions: additions)
        }
        if flags & 0x40 != 0 { packet.overhead = try u8("overhead") }
        if flags & 0x100 != 0 {
            let count = try u8("MaxDelayedAcks"), timeout = try u16("DelayedAckTimeoutInMs")
            packet.delayAck = DelayAck(count: count, milliseconds: timeout)
        }
        if flags & 0x10 != 0 { packet.ackOfAcks = try u16("AckOfAcks sequence") }
        let sequence: UInt16? = flags & 4 != 0 ? try u16("data sequence") : nil
        if flags & 8 != 0 {
            let base = try u16("ACK vector base"), size = try u8("ACK vector size")
            let timestamp = size & 0x80 != 0 ? try u24("ACK vector timestamp") : nil
            let delay: UInt8 = timestamp == nil ? 255 : try u8("ACK vector delay")
            guard size & 0x7F != 0, let coded = b.readBytes(length: Int(size & 0x7F)),
                  !coded.contains(where: { $0 & 0x80 != 0 && $0 & 0x3F == 0 })
            else { throw ParseError.ackVector(size: size) }
            packet.vector = AckVector(base: base, timestamp: timestamp, delayMilliseconds: delay, coded: coded)
        }
        if let sequence {
            let channel: UInt16? = packet.dummy ? nil : try u16("channel sequence")
            packet.data = DataPayload(sequence: sequence, channelSequence: channel,
                                      bytes: b.readBytes(length: b.readableBytes)!)
        } else if b.readableBytes != 0 { throw ParseError.trailingBytes(b.readableBytes) }
        return packet
    }

    static func expand(_ wire: UInt16, near reference: UInt64) -> UInt64 {
        let candidate = reference & ~UInt64(0xFFFF) | UInt64(wire)
        if candidate > reference, candidate - reference > 0x8000, candidate >= 0x10000 {
            return candidate - 0x10000
        }
        if reference > candidate, reference - candidate > 0x8000 { return candidate + 0x10000 }
        return candidate
    }
}
