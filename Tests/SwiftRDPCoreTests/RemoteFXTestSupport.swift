import Foundation
@testable import SwiftRDPCore

// Round-trip quality checks stay outside the production encoder.
extension RemoteFXEncoder {
    struct RoundTripStats: Sendable {
        let maxAbsError: Int
        let mse: Double
        let psnr: Double
    }

    /// Encode/decode a BGRA tile and report error vs the source (RGB channels only).
    static func roundTripTile(
        bgra: [UInt8],
        width: Int = 64,
        height: Int = 64
    ) -> (bgra: [UInt8], stats: RoundTripStats)? {
        let tile = Tile(x: 0, y: 0, width: width, height: height, bgra: bgra)
        guard let decoded = roundTripCoefficientsBGRA(tile: tile) else { return nil }
        let tw = Int(tile.width)
        let th = Int(tile.height)
        var maxErr = 0
        var sumSq = 0.0
        var count = 0
        for row in 0..<th {
            for col in 0..<tw {
                let si = (row * tw + col) * 4
                let di = (row * 64 + col) * 4
                for c in 0..<3 {
                    let e = abs(Int(bgra[si + c]) - Int(decoded[di + c]))
                    maxErr = max(maxErr, e)
                    sumSq += Double(e * e)
                    count += 1
                }
            }
        }
        let mse = sumSq / Double(max(count, 1))
        let psnr = mse <= 1e-12 ? 99.0 : 10.0 * log10((255.0 * 255.0) / mse)
        return (decoded, RoundTripStats(maxAbsError: maxErr, mse: mse, psnr: psnr))
    }

    /// ICT -> DWT -> quant -> dequant -> iDWT -> iICT (no RLGR).
    static func roundTripCoefficientsBGRA(tile: Tile) -> [UInt8]? {
        var r = [Int16](repeating: 0, count: 4096)
        var g = [Int16](repeating: 0, count: 4096)
        var b = [Int16](repeating: 0, count: 4096)
        fillRGBPlanes(tile: tile, r: &r, g: &g, b: &b)

        var y = [Int16](repeating: 0, count: 4096)
        var cb = [Int16](repeating: 0, count: 4096)
        var cr = [Int16](repeating: 0, count: 4096)
        rgbToYCbCrICT(r: r, g: g, b: b, y: &y, cb: &cb, cr: &cr)

        rfxDWT2D(&y)
        rfxQuantize(&y)
        rfxDWT2D(&cb)
        rfxQuantize(&cb)
        rfxDWT2D(&cr)
        rfxQuantize(&cr)

        // Mirror progressive decode: shift = quant(6) - 1 = 5
        dequantLeftShift(&y, shift: 5)
        dequantLeftShift(&cb, shift: 5)
        dequantLeftShift(&cr, shift: 5)
        inverseDWT2D(&y)
        inverseDWT2D(&cb)
        inverseDWT2D(&cr)
        return inverseICTToBGRA(y: y, cb: cb, cr: cr)
    }

    /// DWT -> inverse DWT only (no ICT/quant). Returns max abs error over 4096 samples.
    static func dwtRoundTripMaxError(plane: [Int16]) -> Int {
        precondition(plane.count == 4096)
        var buf = plane
        rfxDWT2D(&buf)
        inverseDWT2D(&buf)
        var maxErr = 0
        for i in 0..<4096 {
            maxErr = max(maxErr, abs(Int(plane[i]) - Int(buf[i])))
        }
        return maxErr
    }

    private static func dequantLeftShift(_ buffer: inout [Int16], shift: Int) {
        guard shift > 0 else { return }
        for i in 0..<4096 {
            buffer[i] = Int16(clamping: Int(buffer[i]) << shift)
        }
    }

    /// FreeRDP `rfx_dwt_2d_decode` (even, HL|LH|HH|LL).
    private static func inverseDWT2D(_ buffer: inout [Int16]) {
        var tmp = [Int16](repeating: 0, count: 4096)
        inverseDWT2DBlock(&buffer, idwt: &tmp, subbandWidth: 8, offset: 3840)
        inverseDWT2DBlock(&buffer, idwt: &tmp, subbandWidth: 16, offset: 3072)
        inverseDWT2DBlock(&buffer, idwt: &tmp, subbandWidth: 32, offset: 0)
    }

    /// Literal port of FreeRDP `rfx_dwt_2d_decode_block` operating at `buffer[offset...]`.
    private static func inverseDWT2DBlock(
        _ buffer: inout [Int16],
        idwt: inout [Int16],
        subbandWidth: Int,
        offset: Int
    ) {
        let totalWidth = subbandWidth << 1
        let band = subbandWidth * subbandWidth

        // Horizontal inverse: sub-bands HL|LH|HH|LL -> L/H rows in idwt[0..<totalWidth*totalWidth]
        for y in 0..<subbandWidth {
            let llBase = offset + 3 * band + y * subbandWidth
            let hlBase = offset + y * subbandWidth
            let lhBase = offset + band + y * subbandWidth
            let hhBase = offset + 2 * band + y * subbandWidth
            let lDst = y * totalWidth
            let hDst = (y + subbandWidth) * totalWidth

            // Even coefficients
            idwt[lDst] = Int16(clamping:
                Int(buffer[llBase]) - ((Int(buffer[hlBase]) + Int(buffer[hlBase]) + 1) >> 1))
            idwt[hDst] = Int16(clamping:
                Int(buffer[lhBase]) - ((Int(buffer[hhBase]) + Int(buffer[hhBase]) + 1) >> 1))
            for n in 1..<subbandWidth {
                let x = n << 1
                idwt[lDst + x] = Int16(clamping:
                    Int(buffer[llBase + n])
                    - ((Int(buffer[hlBase + n - 1]) + Int(buffer[hlBase + n]) + 1) >> 1))
                idwt[hDst + x] = Int16(clamping:
                    Int(buffer[lhBase + n])
                    - ((Int(buffer[hhBase + n - 1]) + Int(buffer[hhBase + n]) + 1) >> 1))
            }

            // Odd coefficients
            for n in 0..<(subbandWidth - 1) {
                let x = n << 1
                idwt[lDst + x + 1] = Int16(clamping:
                    (Int(buffer[hlBase + n]) << 1)
                    + ((Int(idwt[lDst + x]) + Int(idwt[lDst + x + 2])) >> 1))
                idwt[hDst + x + 1] = Int16(clamping:
                    (Int(buffer[hhBase + n]) << 1)
                    + ((Int(idwt[hDst + x]) + Int(idwt[hDst + x + 2])) >> 1))
            }
            let nLast = subbandWidth - 1
            let xLast = nLast << 1
            idwt[lDst + xLast + 1] = Int16(clamping:
                (Int(buffer[hlBase + nLast]) << 1) + Int(idwt[lDst + xLast]))
            idwt[hDst + xLast + 1] = Int16(clamping:
                (Int(buffer[hhBase + nLast]) << 1) + Int(idwt[hDst + xLast]))
        }

        // Vertical inverse -> write back into buffer[offset...]
        for x in 0..<totalWidth {
            // First even sample
            let l0 = Int(idwt[x])
            let h0 = Int(idwt[x + subbandWidth * totalWidth])
            buffer[offset + x] = Int16(clamping: l0 - ((h0 * 2 + 1) >> 1))

            var dst = offset + x
            for n in 1..<subbandWidth {
                let l = Int(idwt[x + n * totalWidth])
                let h = Int(idwt[x + (n + subbandWidth) * totalWidth])
                let hPrev = Int(idwt[x + (n - 1 + subbandWidth) * totalWidth])

                buffer[dst + 2 * totalWidth] = Int16(clamping: l - ((hPrev + h + 1) >> 1))
                buffer[dst + totalWidth] = Int16(clamping:
                    (hPrev << 1) + ((Int(buffer[dst]) + Int(buffer[dst + 2 * totalWidth])) >> 1))
                dst += 2 * totalWidth
            }

            // Last odd sample: FreeRDP uses (*h << 1) + ((*dst * 2) >> 1)
            let hLast = Int(idwt[x + (2 * subbandWidth - 1) * totalWidth])
            buffer[dst + totalWidth] = Int16(clamping: (hLast << 1) + Int(buffer[dst]))
        }
    }

    /// FreeRDP `YCbCrToRGB_16s16s` inverse ICT -> BGRA.
    private static func inverseICTToBGRA(y: [Int16], cb: [Int16], cr: [Int16]) -> [UInt8] {
        var out = [UInt8](repeating: 0xFF, count: 64 * 64 * 4)
        for i in 0..<4096 {
            let cy = (Int64(y[i]) + 4096) << 16
            let cbi = Int64(cb[i])
            let cri = Int64(cr[i])
            let r = cy + cri * 91947
            let g = cy - cbi * 22544 - cri * 46792
            let b = cy + cbi * 115998
            let ri = max(0, min(255, Int(r >> 21)))
            let gi = max(0, min(255, Int(g >> 21)))
            let bi = max(0, min(255, Int(b >> 21)))
            let o = i * 4
            out[o] = UInt8(bi)
            out[o + 1] = UInt8(gi)
            out[o + 2] = UInt8(ri)
            out[o + 3] = 0xFF
        }
        return out
    }
}
