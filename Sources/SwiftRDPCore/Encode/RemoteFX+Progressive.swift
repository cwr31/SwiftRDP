import Foundation

// MARK: - True Progressive RFX (TILE_FIRST / TILE_UPGRADE)
// Wire format + bitplane semantics aligned with MS-RDPEGFX and RDPKit's decoder.
// FreeRDP's compressor is progressive_simple-only; this encoder inverts the decode path.

extension RemoteFXEncoder {
    /// Per-tile quality stage for the progressive ladder.
    public enum TileQualityStage: UInt8, Sendable {
        case none = 0
        /// TILE_FIRST at progressive quant index 0 (coarse).
        case coarse = 1
        /// TILE_UPGRADE at progressive quant index 1 (mid).
        case mid = 2
        /// TILE_UPGRADE quality 0xFF (full) or TILE_SIMPLE bootstrap.
        case full = 3
    }

    /// One tile operation for a progressive REGION.
    public enum TileOp: Sendable {
        case first(tile: Tile, quality: UInt8)
        case upgrade(tile: Tile, quality: UInt8)
        case simple(tile: Tile)
    }

    /// 10-band component quant (HL1…LL3 order used by progressiveBitPositions).
    public struct ComponentQuant: Equatable, Sendable {
        public var hl1, lh1, hh1: UInt8
        public var hl2, lh2, hh2: UInt8
        public var hl3, lh3, hh3: UInt8
        public var ll3: UInt8

        public init(
            hl1: UInt8, lh1: UInt8, hh1: UInt8,
            hl2: UInt8, lh2: UInt8, hh2: UInt8,
            hl3: UInt8, lh3: UInt8, hh3: UInt8,
            ll3: UInt8
        ) {
            self.hl1 = hl1; self.lh1 = lh1; self.hh1 = hh1
            self.hl2 = hl2; self.lh2 = lh2; self.hh2 = hh2
            self.hl3 = hl3; self.lh3 = lh3; self.hh3 = hh3
            self.ll3 = ll3
        }

        public var factors: [UInt8] {
            [hl1, lh1, hh1, hl2, lh2, hh2, hl3, lh3, hh3, ll3]
        }

        /// Full quality progressive quant (all zeros) — quality index 0xFF.
        public static let full = ComponentQuant(
            hl1: 0, lh1: 0, hh1: 0,
            hl2: 0, lh2: 0, hh2: 0,
            hl3: 0, lh3: 0, hh3: 0,
            ll3: 0
        )
    }

    /// RFX_PROGRESSIVE_CODEC_QUANT — 1 quality byte + 3×5-byte component quants.
    public struct ProgressiveCodecQuant: Sendable {
        public var quality: UInt8
        public var y: ComponentQuant
        public var cb: ComponentQuant
        public var cr: ComponentQuant

        public init(quality: UInt8, y: ComponentQuant, cb: ComponentQuant, cr: ComponentQuant) {
            self.quality = quality
            self.y = y
            self.cb = cb
            self.cr = cr
        }
    }

    /// Coarse then mid progressive tables (even DWT). Higher → blurrier first paint.
    public static let progressiveQuantTables: [ProgressiveCodecQuant] = [
        ProgressiveCodecQuant(
            quality: 0,
            y: ComponentQuant(hl1: 4, lh1: 4, hh1: 4, hl2: 3, lh2: 3, hh2: 3, hl3: 2, lh3: 2, hh3: 2, ll3: 1),
            cb: ComponentQuant(hl1: 4, lh1: 4, hh1: 4, hl2: 3, lh2: 3, hh2: 3, hl3: 2, lh3: 2, hh3: 2, ll3: 1),
            cr: ComponentQuant(hl1: 4, lh1: 4, hh1: 4, hl2: 3, lh2: 3, hh2: 3, hl3: 2, lh3: 2, hh3: 2, ll3: 1)
        ),
        ProgressiveCodecQuant(
            quality: 1,
            y: ComponentQuant(hl1: 2, lh1: 2, hh1: 2, hl2: 1, lh2: 1, hh2: 1, hl3: 1, lh3: 1, hh3: 1, ll3: 0),
            cb: ComponentQuant(hl1: 2, lh1: 2, hh1: 2, hl2: 1, lh2: 1, hh2: 1, hl3: 1, lh3: 1, hh3: 1, ll3: 0),
            cr: ComponentQuant(hl1: 2, lh1: 2, hh1: 2, hl2: 1, lh2: 1, hh2: 1, hl3: 1, lh3: 1, hh3: 1, ll3: 0)
        ),
    ]

    /// Even-DWT band ranges (RDPKit originalProgressiveBandRanges).
    static let progressiveBandRanges: [Range<Int>] = [
        0..<1024, 1024..<2048, 2048..<3072,
        3072..<3328, 3328..<3584, 3584..<3840,
        3840..<3904, 3904..<3968, 3968..<4032,
        4032..<4096,
    ]
    static let progressiveLL3Range = 4032..<4096
    /// Regular quant factor for all-6 tables → dequant shift = 5.
    static let regularDequantShift = 5

    // MARK: - Public encode

    /// CAPROGRESSIVE with TILE_FIRST / TILE_UPGRADE / TILE_SIMPLE ops.
    public func encodeProgressiveLadderFrame(
        width: UInt16,
        height: UInt16,
        ops: [TileOp]
    ) -> [UInt8] {
        guard !ops.isEmpty else { return [] }
        var out: [UInt8] = []
        if !progressiveSyncSent {
            RDPLog.gfx.info("GFX: RemoteFX Progressive ladder ENABLED (TILE_FIRST/UPGRADE)")
            progressiveSyncSent = true
        }
        out.append(contentsOf: Self.progressiveBlock(type: Progressive.wbtSync, body: Self.progressiveSyncBody()))
        out.append(contentsOf: Self.progressiveBlock(type: Progressive.wbtContext, body: Self.progressiveContextBody()))
        frameIndex &+= 1
        out.append(contentsOf: Self.progressiveBlock(
            type: Progressive.wbtFrameBegin,
            body: Self.progressiveFrameBeginBody(frameIndex: frameIndex)
        ))

        var tiles: [Tile] = []
        var tileBlocks: [UInt8] = []
        for op in ops {
            switch op {
            case .first(let tile, let quality):
                tiles.append(tile)
                tileBlocks.append(contentsOf: writeTileFirst(tile: tile, quality: quality))
            case .upgrade(let tile, let quality):
                tiles.append(tile)
                tileBlocks.append(contentsOf: writeTileUpgrade(tile: tile, quality: quality))
            case .simple(let tile):
                tiles.append(tile)
                tileBlocks.append(contentsOf: Self.writeTileSimplePublic(tile: tile))
                references.remove(xIndex: Int(tile.x) / 64, yIndex: Int(tile.y) / 64)
            }
        }
        out.append(contentsOf: Self.writeProgressiveLadderRegion(
            width: width, height: height, tiles: tiles, tilesData: tileBlocks
        ))
        out.append(contentsOf: Self.progressiveBlock(type: Progressive.wbtFrameEnd, body: []))
        return out
    }

    /// Next stage after a successful send of `from`.
    public static func nextStage(after from: TileQualityStage) -> TileQualityStage? {
        switch from {
        case .none: return .coarse
        case .coarse: return .mid
        case .mid: return .full
        case .full: return nil
        }
    }

    /// Build ops for pending first-paint and upgrade keys.
    public static func makeTileOps(
        tilesByKey: [UInt64: Tile],
        stages: [UInt64: TileQualityStage],
        firstKeys: [UInt64],
        upgradeKeys: [UInt64],
        allowUpgrade: Bool,
        maxOps: Int
    ) -> (ops: [TileOp], advanced: [(UInt64, TileQualityStage)]) {
        var ops: [TileOp] = []
        var advanced: [(UInt64, TileQualityStage)] = []
        for key in firstKeys {
            guard ops.count < maxOps, let tile = tilesByKey[key] else { continue }
            ops.append(.first(tile: tile, quality: 0))
            advanced.append((key, .coarse))
        }
        guard allowUpgrade else { return (ops, advanced) }
        for key in upgradeKeys {
            guard ops.count < maxOps, let tile = tilesByKey[key] else { continue }
            let stage = stages[key] ?? .none
            switch stage {
            case .coarse:
                ops.append(.upgrade(tile: tile, quality: 1))
                advanced.append((key, .mid))
            case .mid:
                ops.append(.upgrade(tile: tile, quality: 0xFF))
                advanced.append((key, .full))
            default:
                break
            }
        }
        return (ops, advanced)
    }

    // MARK: - REGION with progressive quants

    static func writeProgressiveLadderRegion(
        width: UInt16,
        height: UInt16,
        tiles: [Tile],
        tilesData: [UInt8]
    ) -> [UInt8] {
        _ = width
        _ = height
        let numQuant: UInt8 = 1
        let progTables = progressiveQuantTables
        let numProgQuant = UInt8(progTables.count)
        let numTiles = UInt16(tiles.count)
        let numRects = numTiles
        let tilesDataSize = UInt32(tilesData.count)
        let blockLen = UInt32(18)
            + UInt32(numRects) * 8
            + UInt32(numQuant) * 5
            + UInt32(numProgQuant) * 16
            + tilesDataSize

        var out: [UInt8] = []
        out.appendU16(Progressive.wbtRegion)
        out.appendU32(blockLen)
        out.appendU8(64)
        out.appendU16(numRects)
        out.appendU8(numQuant)
        out.appendU8(numProgQuant)
        out.appendU8(0) // even DWT
        out.appendU16(numTiles)
        out.appendU32(tilesDataSize)
        for tile in tiles {
            out.appendU16(tile.x)
            out.appendU16(tile.y)
            out.appendU16(tile.width)
            out.appendU16(tile.height)
        }
        // Regular quant — all 6s (highest RFX quality).
        let q = rfxQuant
        out.append(UInt8((q[0] & 0xF) | ((q[2] & 0xF) << 4)))
        out.append(UInt8((q[1] & 0xF) | ((q[3] & 0xF) << 4)))
        out.append(UInt8((q[5] & 0xF) | ((q[4] & 0xF) << 4)))
        out.append(UInt8((q[6] & 0xF) | ((q[8] & 0xF) << 4)))
        out.append(UInt8((q[7] & 0xF) | ((q[9] & 0xF) << 4)))
        for table in progTables {
            out.append(contentsOf: packProgressiveCodecQuant(table))
        }
        out.append(contentsOf: tilesData)
        return out
    }

    static func packProgressiveCodecQuant(_ q: ProgressiveCodecQuant) -> [UInt8] {
        var out: [UInt8] = [q.quality]
        out.append(contentsOf: packComponentQuant(q.y))
        out.append(contentsOf: packComponentQuant(q.cb))
        out.append(contentsOf: packComponentQuant(q.cr))
        return out
    }

    /// Progressive RFX_COMPONENT_CODEC_QUANT packing (same as REGION regular quant).
    static func packComponentQuant(_ c: ComponentQuant) -> [UInt8] {
        // RDPKit parseProgressiveQuant: ll3|lh3, hl3|hh3, lh2|hl2, hh2|lh1, hl1|hh1
        // But progressiveBitPositions uses factors order hl1,lh1,hh1,...
        // Regular REGION packing in our encoder uses RDPRFX index order into 5 bytes.
        // RDPKit parseProgressiveQuant:
        //   ll3 = b0&0xF, lh3 = b0>>4, hl3 = b1&0xF, hh3 = b1>>4,
        //   lh2 = b2&0xF, hl2 = b2>>4, hh2 = b3&0xF, lh1 = b3>>4,
        //   hl1 = b4&0xF, hh1 = b4>>4
        return [
            UInt8((c.ll3 & 0xF) | ((c.lh3 & 0xF) << 4)),
            UInt8((c.hl3 & 0xF) | ((c.hh3 & 0xF) << 4)),
            UInt8((c.lh2 & 0xF) | ((c.hl2 & 0xF) << 4)),
            UInt8((c.hh2 & 0xF) | ((c.lh1 & 0xF) << 4)),
            UInt8((c.hl1 & 0xF) | ((c.hh1 & 0xF) << 4)),
        ]
    }

    static func progressiveBitPositions(_ quant: ComponentQuant) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 4096)
        for (range, factor) in zip(progressiveBandRanges, quant.factors) {
            for i in range { result[i] = factor }
        }
        return result
    }

    static func resolveProgressiveQuant(quality: UInt8) -> (y: ComponentQuant, cb: ComponentQuant, cr: ComponentQuant) {
        if quality == 0xFF {
            return (.full, .full, .full)
        }
        let idx = Int(quality)
        let table = progressiveQuantTables[min(idx, progressiveQuantTables.count - 1)]
        return (table.y, table.cb, table.cr)
    }

    // MARK: - TILE_SIMPLE (shared)

    static func writeTileSimplePublic(tile: Tile) -> [UInt8] {
        let encoded = encodeTileComponentsInternal(tile: tile)
        let blockLen = UInt32(22 + encoded.y.count + encoded.cb.count + encoded.cr.count)
        var out: [UInt8] = []
        out.appendU16(Progressive.wbtTileSimple)
        out.appendU32(blockLen)
        out.appendU8(0); out.appendU8(0); out.appendU8(0)
        out.appendU16(tile.x / 64)
        out.appendU16(tile.y / 64)
        out.appendU8(0)
        out.appendU16(UInt16(clamping: encoded.y.count))
        out.appendU16(UInt16(clamping: encoded.cb.count))
        out.appendU16(UInt16(clamping: encoded.cr.count))
        out.appendU16(0)
        out.append(contentsOf: encoded.y)
        out.append(contentsOf: encoded.cb)
        out.append(contentsOf: encoded.cr)
        return out
    }

    // MARK: - TILE_FIRST

    private func writeTileFirst(tile: Tile, quality: UInt8) -> [UInt8] {
        let xIdx = Int(tile.x) / 64
        let yIdx = Int(tile.y) / 64
        let prog = Self.resolveProgressiveQuant(quality: quality)
        let prepared = Self.prepareComponentWires(tile: tile)
        let yEnc = Self.encodeFirstComponent(prepared.y, prog: prog.y)
        let cbEnc = Self.encodeFirstComponent(prepared.cb, prog: prog.cb)
        let crEnc = Self.encodeFirstComponent(prepared.cr, prog: prog.cr)

        references.store(
            xIndex: xIdx,
            yIndex: yIdx,
            y: yEnc.state,
            cb: cbEnc.state,
            cr: crEnc.state
        )

        let blockLen = UInt32(23 + yEnc.bytes.count + cbEnc.bytes.count + crEnc.bytes.count)
        var out: [UInt8] = []
        out.appendU16(Progressive.wbtTileFirst)
        out.appendU32(blockLen)
        out.appendU8(0); out.appendU8(0); out.appendU8(0)
        out.appendU16(UInt16(xIdx))
        out.appendU16(UInt16(yIdx))
        out.appendU8(0) // flags
        out.appendU8(quality)
        out.appendU16(UInt16(clamping: yEnc.bytes.count))
        out.appendU16(UInt16(clamping: cbEnc.bytes.count))
        out.appendU16(UInt16(clamping: crEnc.bytes.count))
        out.appendU16(0) // tailLen
        out.append(contentsOf: yEnc.bytes)
        out.append(contentsOf: cbEnc.bytes)
        out.append(contentsOf: crEnc.bytes)
        return out
    }

    private struct FirstComponentResult {
        var bytes: [UInt8]
        var state: ProgressiveComponentEncodeState
    }

    /// Invert RDPKit decodeProgressiveFirstComponent.
    private static func encodeFirstComponent(
        _ fullW: [Int16],
        prog: ComponentQuant
    ) -> FirstComponentResult {
        let bitPos = progressiveBitPositions(prog)
        var wire = [Int16](repeating: 0, count: 4096)
        var signs = [Int8](repeating: 0, count: 4096)
        var coeffs = [Int16](repeating: 0, count: 4096)

        for i in 0..<4096 {
            let p = Int(bitPos[i])
            let w = Int(fullW[i])
            let shifted: Int
            if p == 0 {
                shifted = w
            } else if w >= 0 {
                shifted = w >> p
            } else {
                shifted = -((-w) >> p)
            }
            wire[i] = Int16(clamping: shifted)
            if progressiveLL3Range.contains(i) {
                signs[i] = 0
            } else if shifted < 0 {
                signs[i] = -1
            } else if shifted > 0 {
                signs[i] = 1
            } else {
                signs[i] = 0
            }
            // Decoder: wire <<= p then <<= regularDequantShift
            coeffs[i] = Int16(clamping: (shifted << p) << regularDequantShift)
        }

        var forRLGR = wire
        rfxDifferentialLL3(&forRLGR)
        let bytes = rfxRLGR1Encode(forRLGR)
        return FirstComponentResult(
            bytes: bytes,
            state: ProgressiveComponentEncodeState(
                fullW: fullW,
                coefficients: coeffs,
                signs: signs,
                bitPositions: bitPos
            )
        )
    }

    // MARK: - TILE_UPGRADE

    private func writeTileUpgrade(tile: Tile, quality: UInt8) -> [UInt8] {
        let xIdx = Int(tile.x) / 64
        let yIdx = Int(tile.y) / 64
        guard var stored = references.state(xIndex: xIdx, yIndex: yIdx) else {
            // No FIRST state — fall back to SIMPLE full tile.
            return Self.writeTileSimplePublic(tile: tile)
        }
        let target = Self.resolveProgressiveQuant(quality: quality)
        let yStreams = Self.encodeUpgradeComponent(state: &stored.y, target: target.y)
        let cbStreams = Self.encodeUpgradeComponent(state: &stored.cb, target: target.cb)
        let crStreams = Self.encodeUpgradeComponent(state: &stored.cr, target: target.cr)
        references.store(xIndex: xIdx, yIndex: yIdx, y: stored.y, cb: stored.cb, cr: stored.cr)

        let lengths = [
            yStreams.srl.count, yStreams.raw.count,
            cbStreams.srl.count, cbStreams.raw.count,
            crStreams.srl.count, crStreams.raw.count,
        ]
        var payload: [UInt8] = []
        payload.reserveCapacity(lengths.reduce(0, +))
        payload.append(contentsOf: yStreams.srl)
        payload.append(contentsOf: yStreams.raw)
        payload.append(contentsOf: cbStreams.srl)
        payload.append(contentsOf: cbStreams.raw)
        payload.append(contentsOf: crStreams.srl)
        payload.append(contentsOf: crStreams.raw)
        let blockLen = UInt32(26 + payload.count)
        var out: [UInt8] = []
        out.appendU16(Progressive.wbtTileUpgrade)
        out.appendU32(blockLen)
        out.appendU8(0); out.appendU8(0); out.appendU8(0)
        out.appendU16(UInt16(xIdx))
        out.appendU16(UInt16(yIdx))
        out.appendU8(quality)
        for len in lengths {
            out.appendU16(UInt16(clamping: len))
        }
        out.append(contentsOf: payload)
        return out
    }

    private struct UpgradeStreams {
        var srl: [UInt8]
        var raw: [UInt8]
    }

    /// Invert RDPKit decodeProgressiveUpgradeComponent.
    private static func encodeUpgradeComponent(
        state: inout ProgressiveComponentEncodeState,
        target: ComponentQuant
    ) -> UpgradeStreams {
        let targetPos = progressiveBitPositions(target)
        var bitCounts = [Int](repeating: 0, count: 4096)
        for i in 0..<4096 {
            let cur = Int(state.bitPositions[i])
            let tgt = Int(targetPos[i])
            bitCounts[i] = max(0, cur - tgt)
        }

        var srlValues: [(index: Int, value: Int16, bits: Int)] = []
        var rawBits = RFXBitWriter(capacity: 512)

        for i in 0..<4096 where bitCounts[i] > 0 {
            let bits = bitCounts[i]
            let tgt = Int(targetPos[i])
            let w = Int(state.fullW[i])
            // Bits of W in [tgt, cur).
            let mask = (1 << bits) - 1
            let unsignedChunk: Int
            if w >= 0 {
                unsignedChunk = (w >> tgt) & mask
            } else {
                // Two's-complement style chunk for negative values.
                unsignedChunk = ((-w) >> tgt) & mask
            }

            let useSRL = i < progressiveLL3Range.lowerBound && state.signs[i] == 0
            if useSRL {
                // Introduce a previously-zero coefficient (or refine from zero).
                let signed: Int16
                if w >= 0 {
                    signed = Int16(clamping: unsignedChunk)
                } else {
                    signed = Int16(clamping: -unsignedChunk)
                }
                srlValues.append((i, signed, bits))
                if signed < 0 { state.signs[i] = -1 }
                else if signed > 0 { state.signs[i] = 1 }
                let shift = tgt + regularDequantShift
                state.coefficients[i] = Int16(clamping: Int(state.coefficients[i]) + (Int(signed) << shift))
            } else {
                rawBits.putBits(UInt32(unsignedChunk), count: bits)
                let input: Int
                if i < progressiveLL3Range.lowerBound && state.signs[i] < 0 {
                    input = -unsignedChunk
                } else {
                    input = unsignedChunk
                }
                let shift = tgt + regularDequantShift
                state.coefficients[i] = Int16(clamping: Int(state.coefficients[i]) + (input << shift))
            }
        }

        let srlData = ProgressiveSRLWriter.encode(srlValues)
        state.bitPositions = targetPos
        return UpgradeStreams(srl: srlData, raw: rawBits.finish())
    }

    // MARK: - Shared prep

    /// DWT + ICT>>5 coefficients (SIMPLE wire domain before LL3 diff / RLGR).
    static func prepareComponentWires(tile: Tile) -> (y: [Int16], cb: [Int16], cr: [Int16]) {
        var r = [Int16](repeating: 0, count: 4096)
        var g = [Int16](repeating: 0, count: 4096)
        var b = [Int16](repeating: 0, count: 4096)
        fillRGBPlanes(tile: tile, r: &r, g: &g, b: &b)
        var y = [Int16](repeating: 0, count: 4096)
        var cb = [Int16](repeating: 0, count: 4096)
        var cr = [Int16](repeating: 0, count: 4096)
        rgbToYCbCrICT(r: r, g: g, b: b, y: &y, cb: &cb, cr: &cr)
        rfxDWT2D(&y); rfxQuantize(&y)
        rfxDWT2D(&cb); rfxQuantize(&cb)
        rfxDWT2D(&cr); rfxQuantize(&cr)
        return (y, cb, cr)
    }

    static func encodeTileComponentsInternal(tile: Tile) -> (y: [UInt8], cb: [UInt8], cr: [UInt8]) {
        let prepared = prepareComponentWires(tile: tile)
        var y = prepared.y
        var cb = prepared.cb
        var cr = prepared.cr
        rfxDifferentialLL3(&y)
        rfxDifferentialLL3(&cb)
        rfxDifferentialLL3(&cr)
        return (rfxRLGR1Encode(y), rfxRLGR1Encode(cb), rfxRLGR1Encode(cr))
    }
}

// MARK: - Encoder-side progressive reference store

struct ProgressiveComponentEncodeState {
    var fullW: [Int16]
    var coefficients: [Int16]
    var signs: [Int8]
    var bitPositions: [UInt8]
}

struct ProgressiveTileEncodeState {
    var y: ProgressiveComponentEncodeState
    var cb: ProgressiveComponentEncodeState
    var cr: ProgressiveComponentEncodeState
}

final class ProgressiveReferenceStore {
    private var tiles: [UInt64: ProgressiveTileEncodeState] = [:]

    private static func key(xIndex: Int, yIndex: Int) -> UInt64 {
        (UInt64(UInt32(bitPattern: Int32(xIndex))) << 32) | UInt64(UInt32(bitPattern: Int32(yIndex)))
    }

    func reset() {
        tiles.removeAll(keepingCapacity: true)
    }

    func store(
        xIndex: Int, yIndex: Int,
        y: ProgressiveComponentEncodeState,
        cb: ProgressiveComponentEncodeState,
        cr: ProgressiveComponentEncodeState
    ) {
        tiles[Self.key(xIndex: xIndex, yIndex: yIndex)] = ProgressiveTileEncodeState(y: y, cb: cb, cr: cr)
    }

    func state(xIndex: Int, yIndex: Int) -> ProgressiveTileEncodeState? {
        return tiles[Self.key(xIndex: xIndex, yIndex: yIndex)]
    }

    func remove(xIndex: Int, yIndex: Int) {
        tiles[Self.key(xIndex: xIndex, yIndex: yIndex)] = nil
    }
}

// MARK: - Progressive SRL writer (inverse of RDPKit RDPProgressiveSRLReader)

enum ProgressiveSRLWriter {
    static func encode(_ values: [(index: Int, value: Int16, bits: Int)]) -> [UInt8] {
        guard !values.isEmpty else { return [] }
        var bs = RFXBitWriter(capacity: max(64, values.count * 4))
        var kp = 8
        var i = 0
        let n = values.count
        while i < n {
            // Count leading zeros in the value stream (value == 0).
            var zeroCount = 0
            while i + zeroCount < n, values[i + zeroCount].value == 0 {
                zeroCount += 1
            }
            // The progressive decoder returns to zero-run mode after every
            // unary value, including when the next coefficient is non-zero.
            writeZeroRun(&bs, zeroCount: zeroCount, kp: &kp)
            i += zeroCount
            if i >= n { break }
            // Non-zero
            let entry = values[i]
            writeNonzero(&bs, value: entry.value, magnitudeBitCount: entry.bits)
            i += 1
        }
        return bs.finish()
    }

    private static func writeZeroRun(
        _ bs: inout RFXBitWriter,
        zeroCount: Int,
        kp: inout Int
    ) {
        var left = zeroCount
        while left > 0 {
            let k = kp / 8
            let runMax = 1 << k
            if left >= runMax {
                // MS-RDPEGFX 3.1.8.1.5.1: every long-run chunk is followed
                // by another decision using the updated KP value. In
                // particular, an exact chunk still needs the final 1 marker
                // before the next non-zero value.
                bs.putBit(0)
                left -= runMax
                kp = min(80, kp + 4)
                continue
            }
            break
        }
        let k = kp / 8
        bs.putBit(1)
        if k > 0 { bs.putBits(UInt32(left), count: k) }
        kp = max(0, kp - 6)
    }

    private static func writeNonzero(
        _ bs: inout RFXBitWriter,
        value: Int16,
        magnitudeBitCount: Int
    ) {
        let sign: UInt8 = value < 0 ? 1 : 0
        bs.putBit(sign)
        let magnitude = abs(Int(value))
        let maximumMagnitude = (1 << magnitudeBitCount) - 1
        let mag = min(max(magnitude, 1), maximumMagnitude)
        // (mag-1) zeros then a 1, unless mag == max (just max-1 zeros).
        for _ in 0..<(mag - 1) {
            bs.putBit(0)
        }
        if mag < maximumMagnitude {
            bs.putBit(1)
        }
    }
}
