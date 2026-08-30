import Foundation

/// Static virtual channel framing ([MS-RDPBCGR] 2.2.6.1).
enum ChannelPDU {
    static let flagFirst: UInt32 = 0x01
    static let flagLast: UInt32 = 0x02
    static let flagShowProtocol: UInt32 = 0x10

    /// Default `VCChunkSize` / `CHANNEL_CHUNK_LENGTH` (MS-RDPBCGR).
    static let defaultChunkSize = 16_256

    struct Header {
        /// Total logical channel payload length (same on every fragment).
        let length: Int
        let flags: UInt32
        /// This fragment's payload bytes (excludes the 8-byte header).
        let payload: [UInt8]
    }

    /// Parse one CHANNEL_PDU fragment. Fragment payload may be shorter than `length`.
    static func parse(_ data: [UInt8]) -> Header? {
        guard data.count >= 8 else { return nil }
        let length = Int(
            UInt32(data[0]) | UInt32(data[1]) << 8 | UInt32(data[2]) << 16 | UInt32(data[3]) << 24
        )
        let flags = UInt32(data[4]) | UInt32(data[5]) << 8 | UInt32(data[6]) << 16 | UInt32(data[7]) << 24
        guard length >= 0 else { return nil }
        return Header(length: length, flags: flags, payload: Array(data[8...]))
    }

    /// Frame a complete (non-chunked) channel body as a single FIRST|LAST PDU.
    static func wrap(_ body: [UInt8], flags: UInt32 = flagFirst | flagLast) -> [UInt8] {
        frame(totalLength: body.count, flags: flags, payload: body)
    }

    /// Split `body` into CHANNEL_PDU fragments of at most `chunkSize` payload bytes.
    /// Each fragment carries the same total `length` per MS-RDPBCGR 2.2.6.1.
    static func chunk(_ body: [UInt8], chunkSize: Int = defaultChunkSize, extraFlags: UInt32 = 0) -> [[UInt8]] {
        let size = max(1, chunkSize)
        let total = body.count
        if total == 0 {
            return [frame(totalLength: 0, flags: flagFirst | flagLast | extraFlags, payload: [])]
        }
        var out: [[UInt8]] = []
        var offset = 0
        while offset < total {
            let end = min(offset + size, total)
            var flags = extraFlags
            if offset == 0 { flags |= flagFirst }
            if end == total { flags |= flagLast }
            out.append(frame(totalLength: total, flags: flags, payload: Array(body[offset..<end])))
            offset = end
        }
        return out
    }

    private static func frame(totalLength: Int, flags: UInt32, payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.appendU32(UInt32(totalLength))
        out.appendU32(flags)
        out.append(contentsOf: payload)
        return out
    }
}
