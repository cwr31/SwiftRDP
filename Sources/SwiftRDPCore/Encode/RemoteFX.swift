import Foundation

/// MS-RDPEGFX RemoteFX encoder.
///
/// The encoder is owned by one GFX pipeline and is only used from that
/// pipeline's serial RFX queue. Progressive references therefore cannot leak
/// between RDP sessions or surface generations.
public final class RemoteFXEncoder: @unchecked Sendable {
    public struct Tile: Sendable {
        public let x: UInt16
        public let y: UInt16
        public let width: UInt16
        public let height: UInt16
        public let bgr: (UInt8, UInt8, UInt8)
        /// Optional top-down BGRA for this tile (`width * height * 4`). Missing → solid `bgr`.
        public let bgra: [UInt8]?

        public init(
            x: Int,
            y: Int,
            width: Int = 64,
            height: Int = 64,
            bgr: (UInt8, UInt8, UInt8) = (0, 0, 0),
            bgra: [UInt8]? = nil
        ) {
            self.x = UInt16(clamping: max(0, x))
            self.y = UInt16(clamping: max(0, y))
            self.width = UInt16(clamping: max(1, min(width, 64)))
            self.height = UInt16(clamping: max(1, min(height, 64)))
            self.bgr = bgr
            self.bgra = bgra
        }
    }

    var frameIndex: UInt32 = 0
    var progressiveSyncSent = false
    let references = ProgressiveReferenceStore()

    public init() {}

    /// Reset all codec state for a new Graphics surface or capability selection.
    public func reset() {
        frameIndex = 0
        progressiveSyncSent = false
        references.reset()
    }

    // MARK: - Progressive block builders (type u16 LE, then len u32 LE)

    static func progressiveBlock(type: UInt16, body: [UInt8]) -> [UInt8] {
        let blockLen = UInt32(6 + body.count)
        var out: [UInt8] = []
        out.appendU16(type)
        out.appendU32(blockLen)
        out.append(contentsOf: body)
        return out
    }

    static func progressiveSyncBody() -> [UInt8] {
        var b: [UInt8] = []
        b.appendU32(Progressive.magic)
        b.appendU16(Progressive.version)
        return b
    }

    static func progressiveContextBody() -> [UInt8] {
        var b: [UInt8] = []
        b.appendU8(0) // ctxId
        b.appendU16(64) // tileSize
        b.appendU8(0) // flags — no SUBBAND_DIFFING (FreeRDP progressive_simple)
        return b
    }

    static func progressiveFrameBeginBody(frameIndex: UInt32) -> [UInt8] {
        var b: [UInt8] = []
        b.appendU32(frameIndex)
        b.appendU16(1) // regionCount
        return b
    }

    // MARK: - Encode: BGRA → YCbCr ICT → CompRefine

    private struct ComponentStreams {
        var y: [UInt8]
        var cb: [UInt8]
        var cr: [UInt8]
    }

    /// Minimum legal RFX quantization gives the clearest text and UI edges.
    static let rfxQuant: [UInt32] = [6, 6, 6, 6, 6, 6, 6, 6, 6, 6]

    /// Even DWT band layout (FreeRDP rfx_dwt_2d_encode) — HL|LH|HH|LL per level.
    static let rfxBands: [(offset: Int, count: Int, quantIdx: Int)] = [
        (0, 1024, 8),       // HL1 32×32
        (1024, 1024, 7),    // LH1 32×32
        (2048, 1024, 9),    // HH1 32×32
        (3072, 256, 5),     // HL2 16×16
        (3328, 256, 4),     // LH2 16×16
        (3584, 256, 6),     // HH2 16×16
        (3840, 64, 2),      // HL3 8×8
        (3904, 64, 1),      // LH3 8×8
        (3968, 64, 3),      // HH3 8×8
        (4032, 64, 0),      // LL3 8×8
    ]

    private static func encodeTileComponents(tile: Tile) -> ComponentStreams {
        var r = [Int16](repeating: 0, count: 4096)
        var g = [Int16](repeating: 0, count: 4096)
        var b = [Int16](repeating: 0, count: 4096)
        fillRGBPlanes(tile: tile, r: &r, g: &g, b: &b)

        var y = [Int16](repeating: 0, count: 4096)
        var cb = [Int16](repeating: 0, count: 4096)
        var cr = [Int16](repeating: 0, count: 4096)
        rgbToYCbCrICT(r: r, g: g, b: b, y: &y, cb: &cb, cr: &cr)

        return ComponentStreams(
            y: compRefineEncode(&y),
            cb: compRefineEncode(&cb),
            cr: compRefineEncode(&cr)
        )
    }

    static func fillRGBPlanes(tile: Tile, r: inout [Int16], g: inout [Int16], b: inout [Int16]) {
        let tw = Int(tile.width)
        let th = Int(tile.height)
        if let bgra = tile.bgra, bgra.count >= tw * th * 4 {
            for row in 0..<th {
                for col in 0..<tw {
                    let si = (row * tw + col) * 4
                    let di = row * 64 + col
                    b[di] = Int16(bgra[si])
                    g[di] = Int16(bgra[si + 1])
                    r[di] = Int16(bgra[si + 2])
                }
                if tw < 64 {
                    let lastR = r[row * 64 + tw - 1]
                    let lastG = g[row * 64 + tw - 1]
                    let lastB = b[row * 64 + tw - 1]
                    for col in tw..<64 {
                        r[row * 64 + col] = lastR
                        g[row * 64 + col] = lastG
                        b[row * 64 + col] = lastB
                    }
                }
            }
            if th < 64 {
                let srcRow = (th - 1) * 64
                for row in th..<64 {
                    for col in 0..<64 {
                        r[row * 64 + col] = r[srcRow + col]
                        g[row * 64 + col] = g[srcRow + col]
                        b[row * 64 + col] = b[srcRow + col]
                    }
                }
            }
        } else {
            let rv = Int16(tile.bgr.2)
            let gv = Int16(tile.bgr.1)
            let bv = Int16(tile.bgr.0)
            for i in 0..<4096 {
                r[i] = rv
                g[i] = gv
                b[i] = bv
            }
        }
    }

    /// ICT (RemoteFX, scaled <<5).
    static func rgbToYCbCrICT(
        r: [Int16], g: [Int16], b: [Int16],
        y: inout [Int16], cb: inout [Int16], cr: inout [Int16]
    ) {
        for i in 0..<4096 {
            let ri = Int32(r[i])
            let gi = Int32(g[i])
            let bi = Int32(b[i])
            let cy = (ri * 9798 + gi * 19235 + bi * 3735) >> 10
            let cbi = (ri * -5535 + gi * -10868 + bi * 16403) >> 10
            let cri = (ri * 16377 + gi * -13714 + bi * -2663) >> 10
            y[i] = Int16(clamping: min(max(cy - 4096, -4096), 4095))
            cb[i] = Int16(clamping: min(max(cbi, -4096), 4095))
            cr[i] = Int16(clamping: min(max(cri, -4096), 4095))
        }
    }

    /// DWT → quant → diff LL → RLGR1.
    private static func compRefineEncode(_ src: inout [Int16]) -> [UInt8] {
        rfxDWT2D(&src)
        rfxQuantize(&src)
        rfxDifferentialLL3(&src)
        return rfxRLGR1Encode(src)
    }

    // MARK: - DWT 5/3 even (FreeRDP rfx_dwt_2d_encode)

    /// Even subbands: 64→32/32, 32→16/16, 16→8/8. Pack HL|LH|HH|LL per level.
    static func rfxDWT2D(_ buffer: inout [Int16]) {
        var dwt = [Int16](repeating: 0, count: 4096)
        rfxDWT2DEncodeBlock(&buffer, dwt: &dwt, subbandWidth: 32, offset: 0)
        rfxDWT2DEncodeBlock(&buffer, dwt: &dwt, subbandWidth: 16, offset: 3072)
        rfxDWT2DEncodeBlock(&buffer, dwt: &dwt, subbandWidth: 8, offset: 3840)
    }

    /// Literal port of FreeRDP `rfx_dwt_2d_encode_block`.
    static func rfxDWT2DEncodeBlock(
        _ buffer: inout [Int16],
        dwt: inout [Int16],
        subbandWidth: Int,
        offset: Int
    ) {
        let totalWidth = subbandWidth << 1
        let band = subbandWidth * subbandWidth

        // Vertical → L then H in dwt[0..<totalWidth*totalWidth]
        for x in 0..<totalWidth {
            for n in 0..<subbandWidth {
                let y = n << 1
                let lIdx = n * totalWidth + x
                let hIdx = lIdx + subbandWidth * totalWidth
                let srcBase = offset + y * totalWidth + x
                let src0 = Int(buffer[srcBase])
                let src1 = Int(buffer[srcBase + totalWidth])
                let src2 = n < subbandWidth - 1
                    ? Int(buffer[srcBase + 2 * totalWidth])
                    : src0
                let h = (src1 - ((src0 + src2) >> 1)) >> 1
                dwt[hIdx] = Int16(clamping: h)
                let l: Int
                if n == 0 {
                    l = src0 + Int(dwt[hIdx])
                } else {
                    l = src0 + ((Int(dwt[hIdx - totalWidth]) + Int(dwt[hIdx])) >> 1)
                }
                dwt[lIdx] = Int16(clamping: l)
            }
        }

        // Horizontal → HL|LH|HH|LL in buffer[offset...]
        let hlOff = offset
        let lhOff = offset + band
        let hhOff = offset + 2 * band
        let llOff = offset + 3 * band

        for y in 0..<subbandWidth {
            let lRow = y * totalWidth
            let hRow = (y + subbandWidth) * totalWidth
            for n in 0..<subbandWidth {
                let x = n << 1
                let l0 = Int(dwt[lRow + x])
                let l1 = Int(dwt[lRow + x + 1])
                let l2 = Int(dwt[lRow + (n < subbandWidth - 1 ? x + 2 : x)])
                let hl = (l1 - ((l0 + l2) >> 1)) >> 1
                buffer[hlOff + y * subbandWidth + n] = Int16(clamping: hl)
                let ll: Int
                if n == 0 {
                    ll = l0 + Int(buffer[hlOff + y * subbandWidth + n])
                } else {
                    ll = l0 + ((Int(buffer[hlOff + y * subbandWidth + n - 1])
                        + Int(buffer[hlOff + y * subbandWidth + n])) >> 1)
                }
                buffer[llOff + y * subbandWidth + n] = Int16(clamping: ll)

                let h0 = Int(dwt[hRow + x])
                let h1 = Int(dwt[hRow + x + 1])
                let h2 = Int(dwt[hRow + (n < subbandWidth - 1 ? x + 2 : x)])
                let hh = (h1 - ((h0 + h2) >> 1)) >> 1
                buffer[hhOff + y * subbandWidth + n] = Int16(clamping: hh)
                let lh: Int
                if n == 0 {
                    lh = h0 + Int(buffer[hhOff + y * subbandWidth + n])
                } else {
                    lh = h0 + ((Int(buffer[hhOff + y * subbandWidth + n - 1])
                        + Int(buffer[hhOff + y * subbandWidth + n])) >> 1)
                }
                buffer[lhOff + y * subbandWidth + n] = Int16(clamping: lh)
            }
        }
    }

    // MARK: - quant + diff

    static func rfxQuantize(_ buffer: inout [Int16]) {
        for band in rfxBands {
            let q = Int(rfxQuant[band.quantIdx])
            if q >= 7 {
                let round = 1 << (q - 7)
                let shift = q - 6
                let end = band.offset + band.count
                for i in band.offset..<end {
                    buffer[i] = Int16(clamping: (Int(buffer[i]) + round) >> shift)
                }
            }
        }
        // Undo ICT <<5 — `(c + 16) >> 5` over all 4096.
        for i in 0..<4096 {
            buffer[i] = Int16(clamping: (Int(buffer[i]) + 16) >> 5)
        }
    }

    /// Differential coding of LL3 (8×8 even layout).
    static func rfxDifferentialLL3(_ buffer: inout [Int16]) {
        let start = 4032
        let count = 64
        var prev = buffer[start]
        for i in 1..<count {
            let cur = buffer[start + i]
            buffer[start + i] = cur &- prev
            prev = cur
        }
    }

    // MARK: - RLGR1 entropy (BitWriter via / )

    static let kpMax: UInt32 = 80
    static let lsgr: UInt32 = 3
    static let upGR: Int32 = 4
    static let dnGR: Int32 = 6
    static let uqGR: Int32 = 3
    static let dqGR: Int32 = 3

    static func rfxRLGR1Encode(_ data: [Int16]) -> [UInt8] {
        var bs = RFXBitWriter(capacity: 4096)
        var k: UInt32 = 1
        var kp: UInt32 = 1 << lsgr
        var krp: UInt32 = 1 << lsgr
        var idx = 0
        let n = data.count

        func nextInput() -> Int16 {
            if idx < n {
                let v = data[idx]
                idx += 1
                return v
            }
            return 0
        }

        while idx < n {
            if k != 0 {
                var numZeros: UInt32 = 0
                var input = nextInput()
                while input == 0, idx < n {
                    numZeros += 1
                    input = nextInput()
                }

                var runmax = UInt32(1) << k
                while numZeros >= runmax {
                    bs.putBit(0)
                    numZeros -= runmax
                    k = updateParam(&kp, upGR)
                    runmax = UInt32(1) << k
                }
                bs.putBit(1)
                bs.putBits(numZeros, count: Int(k))

                let mag = UInt32(input < 0 ? -Int32(input) : Int32(input))
                let sign: UInt8 = input < 0 ? 1 : 0
                bs.putBit(sign)
                codeGR(&bs, krp: &krp, val: mag > 0 ? mag &- 1 : 0)
                k = updateParam(&kp, -dnGR)
            } else {
                let input = nextInput()
                let twoMs = get2MagSign(input)
                codeGR(&bs, krp: &krp, val: twoMs)
                if twoMs != 0 {
                    k = updateParam(&kp, -dqGR)
                } else {
                    k = updateParam(&kp, uqGR)
                }
            }
        }
        return bs.finish()
    }

    static func updateParam(_ param: inout UInt32, _ deltaP: Int32) -> UInt32 {
        if deltaP < 0 {
            let ud = UInt32(-deltaP)
            if ud > param { param = 0 } else { param -= ud }
        } else {
            param += UInt32(deltaP)
        }
        if param > kpMax { param = kpMax }
        return param >> lsgr
    }

    static func get2MagSign(_ input: Int16) -> UInt32 {
        if input >= 0 { return UInt32(Int(input) * 2) }
        return UInt32(-Int(input) * 2 - 1)
    }

    static func codeGR(_ bs: inout RFXBitWriter, krp: inout UInt32, val: UInt32) {
        let kr = krp >> lsgr
        let vk = val >> kr
        for _ in 0..<vk { bs.putBit(1) }
        bs.putBit(0)
        if kr > 0 {
            bs.putBits(val & ((1 << kr) - 1), count: Int(kr))
        }
        if vk == 0 {
            _ = updateParam(&krp, -2)
        } else if vk > 1 {
            _ = updateParam(&krp, Int32(vk))
        }
    }
}

// MARK: - Bit writer

struct RFXBitWriter {
    private var bytes: [UInt8]
    private var acc: UInt32 = 0
    private var nbits: Int = 0

    init(capacity: Int) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    mutating func putBit(_ bit: UInt8) {
        acc = (acc << 1) | UInt32(bit & 1)
        nbits += 1
        if nbits == 8 {
            bytes.append(UInt8(acc & 0xFF))
            acc = 0
            nbits = 0
        }
    }

    mutating func putBits(_ pattern: UInt32, count: Int) {
        guard count > 0 else { return }
        for i in stride(from: count - 1, through: 0, by: -1) {
            putBit(UInt8((pattern >> i) & 1))
        }
    }

    mutating func finish() -> [UInt8] {
        if nbits > 0 {
            acc <<= (8 - nbits)
            bytes.append(UInt8(acc & 0xFF))
            acc = 0
            nbits = 0
        }
        return bytes
    }
}

/// Progressive / CAPROGRESSIVE block type IDs (MS-RDPEGFX).
enum Progressive {
    static let magic: UInt32 = 0xCACC_ACCA
    static let version: UInt16 = 0x0100

    static let wbtSync: UInt16 = 0xCCC0
    static let wbtFrameBegin: UInt16 = 0xCCC1
    static let wbtFrameEnd: UInt16 = 0xCCC2
    static let wbtContext: UInt16 = 0xCCC3
    static let wbtRegion: UInt16 = 0xCCC4
    static let wbtTileSimple: UInt16 = 0xCCC5
    static let wbtTileFirst: UInt16 = 0xCCC6
    static let wbtTileUpgrade: UInt16 = 0xCCC7
}
