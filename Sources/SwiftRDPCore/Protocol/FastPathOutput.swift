import Foundation

/// MS-RDPBCGR 2.2.9.1.2 Server Fast-Path Update PDU helpers (CursorTracker path).
public enum FastPathOutput {
    public static let updatePtrNull: UInt8 = 0x5
    public static let updatePtrDefault: UInt8 = 0x6
    public static let updatePtrPosition: UInt8 = 0x8
    public static let updateColor: UInt8 = 0x9
    public static let updateCached: UInt8 = 0xA
    public static let updatePointer: UInt8 = 0xB
    public static let updateLargePointer: UInt8 = 0xC

    /// One update: `updateHeader` + `size` + payload.
    public static func update(code: UInt8, payload: [UInt8]) -> [UInt8] {
        var u: [UInt8] = []
        u.append(code & 0x0F) // fragmentation=0, compression=0
        u.appendU16(UInt16(clamping: payload.count))
        u.append(contentsOf: payload)
        return u
    }

    /// Wrap one or more updates into a Fast-Path Output PDU (no encryption under TLS).
    /// MS-RDPBCGR 2.2.9.1.2: fpOutputHeader action=FASTPATH, reserved MUST be 0, flags in high bits.
    /// Update count is implicit from the length-prefixed update stream (not encoded in reserved).
    public static func wrap(_ updates: [[UInt8]]) -> [UInt8] {
        guard !updates.isEmpty else { return [] }
        var body: [UInt8] = []
        body.reserveCapacity(updates.reduce(0) { $0 + $1.count })
        for u in updates { body.append(contentsOf: u) }

        // fpOutputHeader: action=0 (FASTPATH), reserved=0, flags=0
        var hdr: [UInt8] = [0x00]

        // length = entire PDU including fpOutputHeader + length field(s) + body
        let len1Byte = hdr.count + 1 + body.count
        if len1Byte <= 127 {
            hdr.append(UInt8(len1Byte))
        } else {
            let total = hdr.count + 2 + body.count
            hdr.append(UInt8(0x80 | ((total >> 8) & 0x7F)))
            hdr.append(UInt8(total & 0xFF))
        }
        hdr.append(contentsOf: body)
        return hdr
    }

    public static func cachedPointer(cacheIndex: UInt16) -> [UInt8] {
        var p: [UInt8] = []
        p.appendU16(cacheIndex)
        return wrap([update(code: updateCached, payload: p)])
    }

    public static func pointerPosition(x: Int, y: Int) -> [UInt8] {
        var p: [UInt8] = []
        p.appendU16(UInt16(clamping: max(0, x)))
        p.appendU16(UInt16(clamping: max(0, y)))
        return wrap([update(code: updatePtrPosition, payload: p)])
    }

    public static func pointerDefault() -> [UInt8] {
        wrap([update(code: updatePtrDefault, payload: [])])
    }

    /// Encode a 24-bpp pointer using the RDP New Pointer format.
    ///
    /// The New Pointer update supports the negotiated 32x32 or 96x96 pointer
    /// limits. The Large Pointer update is reserved for pointers larger than
    /// 96x96 and uses 32-bit mask lengths.
    public static func pointer(
        cacheIndex: UInt16,
        hotspotX: Int,
        hotspotY: Int,
        width: Int,
        height: Int,
        xorMask: [UInt8],
        andMask: [UInt8]
    ) -> [UInt8] {
        let isLarge = width > 96 || height > 96
        var p: [UInt8] = []
        p.appendU16(24)
        p.appendU16(cacheIndex)
        p.appendU16(UInt16(clamping: hotspotX))
        p.appendU16(UInt16(clamping: hotspotY))
        p.appendU16(UInt16(clamping: width))
        p.appendU16(UInt16(clamping: height))
        if isLarge {
            p.appendU32(UInt32(clamping: andMask.count))
            p.appendU32(UInt32(clamping: xorMask.count))
        } else {
            p.appendU16(UInt16(clamping: andMask.count))
            p.appendU16(UInt16(clamping: xorMask.count))
        }
        p.append(contentsOf: xorMask)
        p.append(contentsOf: andMask)
        let code = isLarge ? updateLargePointer : updatePointer
        return wrap([update(code: code, payload: p)])
    }
}
