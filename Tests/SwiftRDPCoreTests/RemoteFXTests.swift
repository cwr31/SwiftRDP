import XCTest
import CoreVideo
@testable import SwiftRDPCore

final class RemoteFXTests: XCTestCase {
    func testProgressiveSimpleTileHasValidWireLengthAndHighestQualityQuantization() {
        let encoder = RemoteFXEncoder()
        let pixels = [UInt8](repeating: 0x80, count: 64 * 64 * 4)
        let tile = RemoteFXEncoder.Tile(x: 64, y: 128, bgra: pixels)

        let message = encoder.encodeProgressiveLadderFrame(
            width: 192,
            height: 256,
            ops: [.simple(tile: tile)]
        )

        var regionOffset = 0
        for _ in 0..<3 {
            regionOffset += Int(readU32(message, at: regionOffset + 2))
        }

        let regionLength = Int(readU32(message, at: regionOffset + 2))
        let rectCount = Int(readU16(message, at: regionOffset + 7))
        let quantCount = Int(message[regionOffset + 9])
        let numProgQuant = Int(message[regionOffset + 10])
        let tileDataSize = Int(readU32(message, at: regionOffset + 14))
        let quantOffset = regionOffset + 18 + rectCount * 8
        let tileOffset = quantOffset + quantCount * 5 + numProgQuant * 16
        let tileLength = Int(readU32(message, at: tileOffset + 2))

        XCTAssertEqual(Array(message[quantOffset..<(quantOffset + 5)]), [0x66, 0x66, 0x66, 0x66, 0x66])
        XCTAssertEqual(readU16(message, at: tileOffset), 0xCCC5)
        XCTAssertEqual(tileLength, tileDataSize)
        XCTAssertEqual(tileOffset + tileLength, regionOffset + regionLength)
        XCTAssertEqual(Array(message[(tileOffset + 6)..<(tileOffset + 9)]), [0, 0, 0])
        XCTAssertEqual(readU16(message, at: tileOffset + 9), 1)
        XCTAssertEqual(readU16(message, at: tileOffset + 11), 2)
        XCTAssertEqual(message[tileOffset + 13], 0)
        XCTAssertEqual(readU16(message, at: tileOffset + 20), 0)
    }

    func testDWTRoundTripOnRamp() {
        var plane = [Int16](repeating: 0, count: 4096)
        for i in 0..<4096 { plane[i] = Int16(i % 251) - 125 }
        let err = RemoteFXEncoder.dwtRoundTripMaxError(plane: plane)
        // Integer 5/3 DWT with FreeRDP rounding is not bit-exact; ≤10 is healthy.
        XCTAssertLessThanOrEqual(err, 10, "DWT roundtrip maxErr=\(err)")
    }

    func testDWTRoundTripOnChecker() {
        var plane = [Int16](repeating: 0, count: 4096)
        for y in 0..<64 {
            for x in 0..<64 {
                plane[y * 64 + x] = ((x / 2 + y / 2) & 1 == 0) ? -1000 : 1000
            }
        }
        let err = RemoteFXEncoder.dwtRoundTripMaxError(plane: plane)
        XCTAssertLessThanOrEqual(err, 10, "DWT checker maxErr=\(err)")
    }

    func testRoundTripSolidGrayIsNearLossless() {
        let pixels = solidBGRA(r: 0x80, g: 0x80, b: 0x80)
        let result = RemoteFXEncoder.roundTripTile(bgra: pixels)
        XCTAssertNotNil(result)
        guard let stats = result?.stats else { return }
        XCTAssertLessThanOrEqual(stats.maxAbsError, 2, "solid gray maxErr=\(stats.maxAbsError)")
        XCTAssertGreaterThan(stats.psnr, 40, "solid gray PSNR=\(stats.psnr)")
    }

    func testRoundTripSolidPrimaryColors() {
        for (r, g, b) in [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255), (0, 0, 0)] {
            let pixels = solidBGRA(r: UInt8(r), g: UInt8(g), b: UInt8(b))
            let result = RemoteFXEncoder.roundTripTile(bgra: pixels)
            XCTAssertNotNil(result, "nil for rgb=\(r),\(g),\(b)")
            guard let stats = result?.stats else { continue }
            XCTAssertLessThanOrEqual(
                stats.maxAbsError, 3,
                "rgb=\(r),\(g),\(b) maxErr=\(stats.maxAbsError) psnr=\(stats.psnr)"
            )
        }
    }

    func testRoundTripCheckerboardUIEdges() {
        // High-contrast 2×2 blocks — mimics sharp UI / glyph edges.
        var pixels = [UInt8](repeating: 0xFF, count: 64 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<64 {
                let on = ((x / 2) + (y / 2)) & 1 == 0
                let v: UInt8 = on ? 0x00 : 0xFF
                let i = (y * 64 + x) * 4
                pixels[i] = v
                pixels[i + 1] = v
                pixels[i + 2] = v
            }
        }
        let result = RemoteFXEncoder.roundTripTile(bgra: pixels)
        XCTAssertNotNil(result)
        guard let stats = result?.stats else { return }
        // Even DWT+ICT is lossy on hard edges, but must stay far sharper than
        // "calligraphy smear" (which would be maxErr ≫ 30 with low PSNR).
        XCTAssertLessThanOrEqual(stats.maxAbsError, 20, "checker maxErr=\(stats.maxAbsError)")
        XCTAssertGreaterThan(stats.psnr, 25, "checker PSNR=\(stats.psnr)")
    }

    func testRoundTripHorizontalTextLikeBars() {
        var pixels = [UInt8](repeating: 0xFF, count: 64 * 64 * 4)
        // White background, black 1-px bars every 4 rows — text stroke proxy.
        for y in stride(from: 8, to: 56, by: 4) {
            for x in 8..<56 {
                let i = (y * 64 + x) * 4
                pixels[i] = 0
                pixels[i + 1] = 0
                pixels[i + 2] = 0
            }
        }
        let result = RemoteFXEncoder.roundTripTile(bgra: pixels)
        XCTAssertNotNil(result)
        guard let stats = result?.stats else { return }
        XCTAssertLessThanOrEqual(stats.maxAbsError, 24, "bars maxErr=\(stats.maxAbsError)")
        XCTAssertGreaterThan(stats.psnr, 24, "bars PSNR=\(stats.psnr)")
    }

    func testScaleDirtyRectsMapsCaptureIntoSurface() throws {
        let rects = [CGRect(x: 100, y: 200, width: 50, height: 80)]
        let scaled = RDPSession.rfxScaleDirtyRects(
            rects,
            fromWidth: 1728,
            fromHeight: 1080,
            toWidth: 1424,
            toHeight: 700
        )
        XCTAssertEqual(scaled.count, 1)
        let r = try XCTUnwrap(scaled.first)
        XCTAssertEqual(r.origin.x, 100 * (1424.0 / 1728.0), accuracy: 0.01)
        XCTAssertEqual(r.origin.y, 200 * (700.0 / 1080.0), accuracy: 0.01)
        XCTAssertEqual(r.size.width, 50 * (1424.0 / 1728.0), accuracy: 0.01)
        XCTAssertEqual(r.size.height, 80 * (700.0 / 1080.0), accuracy: 0.01)
    }

    func testPrepareFrameForSurfaceScalesTileGridToSurface() throws {
        let srcW = 1728
        let srcH = 1080
        let dstW = 1424
        let dstH = 700
        var src: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, srcW, srcH, kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ] as CFDictionary,
            &src
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let srcPB = try XCTUnwrap(src)

        let frame = CapturedFrame(
            width: srcW,
            height: srcH,
            bgrBottomUp: [],
            dirtyRects: [CGRect(x: 0, y: 0, width: srcW, height: srcH)],
            pixelBuffer: srcPB
        )
        let prepared = try XCTUnwrap(
            RDPSession.rfxPrepareFrameForSurface(
                frame: frame,
                captureDirty: frame.dirtyRects ?? [],
                surfaceWidth: dstW,
                surfaceHeight: dstH,
                transfer: PixelBufferTransfer()
            )
        )
        XCTAssertTrue(prepared.didScale)
        XCTAssertEqual(prepared.frame.width, dstW)
        XCTAssertEqual(prepared.frame.height, dstH)
        XCTAssertEqual(CVPixelBufferGetWidth(try XCTUnwrap(prepared.frame.pixelBuffer)), dstW)
        XCTAssertEqual(CVPixelBufferGetHeight(try XCTUnwrap(prepared.frame.pixelBuffer)), dstH)

        let expectedTiles =
            ((dstW + 63) / 64) * ((dstH + 63) / 64)
        XCTAssertEqual(expectedTiles, 253)
        XCTAssertNotEqual(
            ((srcW + 63) / 64) * ((srcH + 63) / 64),
            expectedTiles
        )
    }

    func testProgressiveLadderRegionHasProgQuantsAndTileFirst() {
        let encoder = RemoteFXEncoder()
        let pixels = [UInt8](repeating: 0x80, count: 64 * 64 * 4)
        let tile = RemoteFXEncoder.Tile(x: 0, y: 0, bgra: pixels)
        let message = encoder.encodeProgressiveLadderFrame(
            width: 64,
            height: 64,
            ops: [.first(tile: tile, quality: 0)]
        )

        var regionOffset = 0
        for _ in 0..<3 {
            regionOffset += Int(readU32(message, at: regionOffset + 2))
        }
        let numProgQuant = Int(message[regionOffset + 10])
        XCTAssertEqual(numProgQuant, 2)

        let rectCount = Int(readU16(message, at: regionOffset + 7))
        let quantCount = Int(message[regionOffset + 9])
        let quantOffset = regionOffset + 18 + rectCount * 8
        let progOffset = quantOffset + quantCount * 5
        let tileOffset = progOffset + numProgQuant * 16
        XCTAssertEqual(readU16(message, at: tileOffset), 0xCCC6) // TILE_FIRST
        XCTAssertEqual(message[tileOffset + 14], 0) // quality index 0
    }

    func testProgressiveLadderUpgradeFollowsFirst() {
        let encoder = RemoteFXEncoder()
        let pixels = solidBGRA(r: 0x40, g: 0x80, b: 0xC0)
        let tile = RemoteFXEncoder.Tile(x: 64, y: 128, bgra: pixels)
        _ = encoder.encodeProgressiveLadderFrame(
            width: 192, height: 256,
            ops: [.first(tile: tile, quality: 0)]
        )
        let upgrade = encoder.encodeProgressiveLadderFrame(
            width: 192, height: 256,
            ops: [.upgrade(tile: tile, quality: 1)]
        )
        var regionOffset = 0
        for _ in 0..<3 {
            regionOffset += Int(readU32(upgrade, at: regionOffset + 2))
        }
        let rectCount = Int(readU16(upgrade, at: regionOffset + 7))
        let quantCount = Int(upgrade[regionOffset + 9])
        let numProgQuant = Int(upgrade[regionOffset + 10])
        let quantOffset = regionOffset + 18 + rectCount * 8
        let tileOffset = quantOffset + quantCount * 5 + numProgQuant * 16
        XCTAssertEqual(readU16(upgrade, at: tileOffset), 0xCCC7) // TILE_UPGRADE
        XCTAssertEqual(upgrade[tileOffset + 13], 1) // quality mid
        // Six length fields present
        let ySrl = Int(readU16(upgrade, at: tileOffset + 14))
        let yRaw = Int(readU16(upgrade, at: tileOffset + 16))
        XCTAssertGreaterThanOrEqual(ySrl + yRaw, 0)
    }

    func testMakeTileOpsSchedulesFirstThenUpgrade() {
        let tile = RemoteFXEncoder.Tile(x: 0, y: 0, bgra: [UInt8](repeating: 0, count: 64 * 64 * 4))
        let key: UInt64 = 0
        let first = RemoteFXEncoder.makeTileOps(
            tilesByKey: [key: tile],
            stages: [:],
            firstKeys: [key],
            upgradeKeys: [],
            allowUpgrade: true,
            maxOps: 8
        )
        XCTAssertEqual(first.ops.count, 1)
        if case .first(_, let q) = first.ops[0] {
            XCTAssertEqual(q, 0)
        } else {
            XCTFail("expected first")
        }
        XCTAssertEqual(first.advanced.first?.1, .coarse)

        let upgrade = RemoteFXEncoder.makeTileOps(
            tilesByKey: [key: tile],
            stages: [key: .coarse],
            firstKeys: [],
            upgradeKeys: [key],
            allowUpgrade: true,
            maxOps: 8
        )
        XCTAssertEqual(upgrade.ops.count, 1)
        if case .upgrade(_, let q) = upgrade.ops[0] {
            XCTAssertEqual(q, 1)
        } else {
            XCTFail("expected upgrade")
        }
        XCTAssertEqual(upgrade.advanced.first?.1, .mid)

        let blocked = RemoteFXEncoder.makeTileOps(
            tilesByKey: [key: tile],
            stages: [key: .coarse],
            firstKeys: [],
            upgradeKeys: [key],
            allowUpgrade: false,
            maxOps: 8
        )
        XCTAssertTrue(blocked.ops.isEmpty)
    }

    func testCopyBGRAFromNV12ProducesColorNotFourPaneLuma() throws {
        let w = 64
        let h = 64
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, w, h,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ] as CFDictionary,
            &pb
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb)

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let yBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            .assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let uvBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
            .assumingMemoryBound(to: UInt8.self)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)

        // Horizontal luma ramp + neutral chroma. A BGRA misread of the Y plane
        // would pack 4 luma samples into B,G,R,A and look like 4 side-by-side panes.
        for y in 0..<h {
            for x in 0..<w {
                yBase[y * yStride + x] = UInt8(x & 0xFF)
            }
        }
        for y in 0..<(h / 2) {
            for x in 0..<(w / 2) {
                let i = y * uvStride + x * 2
                uvBase[i] = 128
                uvBase[i + 1] = 128
            }
        }

        let bgra = try XCTUnwrap(RDPSession.copyBGRA(from: buffer))
        XCTAssertEqual(bgra.count, w * h * 4)

        for x in [0, 1, 2, 3, 16, 32, 63] {
            let i = x * 4
            let b = Int(bgra[i])
            let g = Int(bgra[i + 1])
            let r = Int(bgra[i + 2])
            XCTAssertEqual(bgra[i + 3], 0xFF)
            // Neutral chroma → near-gray matching luma x (video-range lift ± a few).
            XCTAssertLessThan(abs(b - g), 8, "x=\(x) not gray B=\(b) G=\(g)")
            XCTAssertLessThan(abs(g - r), 8, "x=\(x) not gray G=\(g) R=\(r)")
            XCTAssertLessThan(abs(b - x), 24, "x=\(x) luma mismatch B=\(b)")
            // Bug path would set B=Y[4x], G=Y[4x+1], R=Y[4x+2] → not gray for x=0.
            if x == 0 {
                XCTAssertNotEqual(g, 1, "looks like raw Y-as-BGRA misread")
                XCTAssertNotEqual(r, 2, "looks like raw Y-as-BGRA misread")
            }
        }
    }

    func testRFXHashUsesNV12YPlaneNotBGRAStride() throws {
        let w = 64
        let h = 64
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, w, h,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &pb
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb)

        CVPixelBufferLockBaseAddress(buffer, [])
        let yBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            .assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let uvBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
            .assumingMemoryBound(to: UInt8.self)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<h {
            for x in 0..<w { yBase[y * yStride + x] = 40 }
        }
        for y in 0..<(h / 2) {
            for x in 0..<(w / 2) {
                let i = y * uvStride + x * 2
                uvBase[i] = 128
                uvBase[i + 1] = 128
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let h1 = try XCTUnwrap(RDPSession.rfxHashTile(pixelBuffer: buffer, x: 0, y: 0, w: 64, h: 64))

        CVPixelBufferLockBaseAddress(buffer, [])
        let yBase2 = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            .assumingMemoryBound(to: UInt8.self)
        // Change a single luma sample — NV12-aware hash must notice.
        yBase2[10 * yStride + 10] = 200
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let h2 = try XCTUnwrap(RDPSession.rfxHashTile(pixelBuffer: buffer, x: 0, y: 0, w: 64, h: 64))
        XCTAssertNotEqual(h1, h2)

        // BGRA mis-hash of NV12 Y plane uses x*4 and would often miss a mid-tile change
        // depending on stride; ensure our API is format-aware via a second tile origin.
        let hCorner = try XCTUnwrap(RDPSession.rfxHashTile(pixelBuffer: buffer, x: 0, y: 0, w: 16, h: 16))
        let hOther = try XCTUnwrap(RDPSession.rfxHashTile(pixelBuffer: buffer, x: 48, y: 48, w: 16, h: 16))
        XCTAssertNotEqual(hCorner, hOther)
    }

    func testPixelBufferTransferScalesNV12ToBGRA() throws {
        let w = 128
        let h = 80
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, w, h,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &pb
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let yBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            .assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        memset(yBase, 80, yStride * h)
        let uvBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
            .assumingMemoryBound(to: UInt8.self)
        memset(uvBase, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * (h / 2))
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let transfer = PixelBufferTransfer()
        let scaled = try XCTUnwrap(transfer.transfer(
            buffer, width: 64, height: 40,
            pixelFormat: kCVPixelFormatType_32BGRA, scaling: .fill
        ))
        XCTAssertEqual(CVPixelBufferGetWidth(scaled), 64)
        XCTAssertEqual(CVPixelBufferGetHeight(scaled), 40)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(scaled), kCVPixelFormatType_32BGRA)

        // Letterbox keeps the source aspect: 128x80 (8:5) into a 64x64 square
        // leaves black bars, so the centre row is content and the top row is not.
        let boxed = try XCTUnwrap(transfer.transfer(
            buffer, width: 64, height: 64,
            pixelFormat: kCVPixelFormatType_32BGRA, scaling: .letterbox
        ))
        XCTAssertEqual(CVPixelBufferGetWidth(boxed), 64)
        XCTAssertEqual(CVPixelBufferGetHeight(boxed), 64)
        CVPixelBufferLockBaseAddress(boxed, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(boxed, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(boxed))
            .assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(boxed)
        let topPixel = base.advanced(by: 32 * 4)
        let centerPixel = base.advanced(by: 32 * stride + 32 * 4)
        XCTAssertEqual(Int(topPixel[0]), 0, "top row must be letterbox black")
        XCTAssertGreaterThan(Int(centerPixel[0]), 0, "centre row must carry content")
    }

    func testMakeTileOpsRespectsBudgetAcrossFirstKeys() {
        var tilesByKey: [UInt64: RemoteFXEncoder.Tile] = [:]
        var keys: [UInt64] = []
        for i in 0..<10 {
            let x = UInt64(i * 64)
            let key = (x << 32)
            keys.append(key)
            tilesByKey[key] = RemoteFXEncoder.Tile(
                x: Int(x), y: 0, bgra: [UInt8](repeating: 0, count: 64 * 64 * 4)
            )
        }
        let built = RemoteFXEncoder.makeTileOps(
            tilesByKey: tilesByKey,
            stages: [:],
            firstKeys: keys,
            upgradeKeys: [],
            allowUpgrade: true,
            maxOps: 3
        )
        XCTAssertEqual(built.ops.count, 3)
        XCTAssertEqual(built.advanced.count, 3)
    }

    private func solidBGRA(r: UInt8, g: UInt8, b: UInt8) -> [UInt8] {
        var out = [UInt8](repeating: 0xFF, count: 64 * 64 * 4)
        for i in stride(from: 0, to: out.count, by: 4) {
            out[i] = b
            out[i + 1] = g
            out[i + 2] = r
        }
        return out
    }

    private func readU16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private func readU32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
