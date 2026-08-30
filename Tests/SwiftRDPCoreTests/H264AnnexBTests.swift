import XCTest
@testable import SwiftRDPCore

/// The AVCC → Annex-B conversion is a single pass that also does the NAL
/// filtering and the SPS/PPS prepend; nothing rescans the bitstream afterwards.
final class H264AnnexBTests: XCTestCase {
    private let sps: [UInt8] = [0x67, 0x64, 0x00, 0x1F]
    private let pps: [UInt8] = [0x68, 0xEE, 0x3C, 0xB0]

    func testKeyframePrependsParameterSetsAndKeepsWireNALs() {
        let avcc = lengthPrefixed([
            [0x06, 0x05, 0xAA],             // SEI — dropped
            [0x09, 0x10],                   // AUD — dropped
            [0x65, 0x01, 0x02, 0x03, 0x04], // IDR slice
        ])
        let out = convert(avcc, parameterSets: [sps, pps])

        XCTAssertEqual(nalTypes(out), [7, 8, 5])
        XCTAssertEqual(Array(out.prefix(4)), [0, 0, 0, 1])
        // Byte-exact: start code + SPS + start code + PPS + start code + slice.
        var expected: [UInt8] = [0, 0, 0, 1]
        expected += sps
        expected += [0, 0, 0, 1]
        expected += pps
        expected += [0, 0, 0, 1]
        expected += [0x65, 0x01, 0x02, 0x03, 0x04]
        XCTAssertEqual(out, expected)
    }

    func testDeltaFrameCarriesOnlyTheSlice() {
        let avcc = lengthPrefixed([
            [0x06, 0x01],
            [0x41, 0x9A, 0x02],
        ])
        let out = convert(avcc, parameterSets: [])
        XCTAssertEqual(nalTypes(out), [1])
        XCTAssertEqual(out, [0, 0, 0, 1, 0x41, 0x9A, 0x02])
    }

    func testInBandParameterSetsSurviveWithoutDuplication() {
        let avcc = lengthPrefixed([sps, pps, [0x65, 0x07]])
        let out = convert(avcc, parameterSets: [])
        XCTAssertEqual(nalTypes(out), [7, 8, 5])
    }

    func testShortLengthFieldsAreSupported() {
        // 2-byte length prefixes.
        var avcc: [UInt8] = []
        let nal: [UInt8] = [0x41, 0x11, 0x22]
        avcc.append(UInt8((nal.count >> 8) & 0xFF))
        avcc.append(UInt8(nal.count & 0xFF))
        avcc += nal
        let out = convert(avcc, parameterSets: [], lengthFieldSize: 2)
        XCTAssertEqual(out, [0, 0, 0, 1, 0x41, 0x11, 0x22])
    }

    func testTruncatedInputStopsCleanly() {
        // Declares 8 bytes but only 2 follow.
        let avcc: [UInt8] = [0, 0, 0, 8, 0x41, 0x00]
        XCTAssertEqual(convert(avcc, parameterSets: []), [])
        XCTAssertEqual(convert([], parameterSets: []), [])
        XCTAssertEqual(convert([0, 0, 0, 0], parameterSets: []), [])
    }

    // MARK: - Helpers

    private func convert(
        _ avcc: [UInt8],
        parameterSets: [[UInt8]],
        lengthFieldSize: Int = 4
    ) -> [UInt8] {
        var flat: [UInt8] = []
        var ranges: [(offset: Int, size: Int)] = []
        for set in parameterSets {
            ranges.append((flat.count, set.count))
            flat += set
        }
        // Non-empty backing storage so `baseAddress` is always valid.
        let length = avcc.count
        let source = avcc.isEmpty ? [UInt8(0)] : avcc
        if flat.isEmpty { flat = [0] }
        return source.withUnsafeBufferPointer { src in
            flat.withUnsafeBufferPointer { sets in
                let parameters: [(pointer: UnsafePointer<UInt8>, size: Int)] = ranges.map {
                    (pointer: sets.baseAddress! + $0.offset, size: $0.size)
                }
                return H264Encoder.annexBAccessUnit(
                    avcc: src.baseAddress!,
                    length: length,
                    lengthFieldSize: lengthFieldSize,
                    parameterSets: parameters
                )
            }
        }
    }

    private func lengthPrefixed(_ nals: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        for nal in nals {
            let length = UInt32(nal.count)
            out.append(UInt8((length >> 24) & 0xFF))
            out.append(UInt8((length >> 16) & 0xFF))
            out.append(UInt8((length >> 8) & 0xFF))
            out.append(UInt8(length & 0xFF))
            out += nal
        }
        return out
    }

    private func nalTypes(_ annexB: [UInt8]) -> [UInt8] {
        var types: [UInt8] = []
        var index = 0
        while index + 4 <= annexB.count {
            guard annexB[index] == 0, annexB[index + 1] == 0,
                  annexB[index + 2] == 0, annexB[index + 3] == 1 else {
                index += 1
                continue
            }
            let header = index + 4
            guard header < annexB.count else { break }
            types.append(annexB[header] & 0x1F)
            index = header + 1
        }
        return types
    }
}
