import XCTest
@testable import SwiftRDPCore

final class FastPathOutputTests: XCTestCase {
    func testPointerUsesStandardFormatAt32Pixels() {
        let pdu = FastPathOutput.pointer(
            cacheIndex: 3,
            hotspotX: 4,
            hotspotY: 5,
            width: 32,
            height: 32,
            xorMask: [UInt8](repeating: 0x11, count: 3_072),
            andMask: [UInt8](repeating: 0x22, count: 128)
        )

        let update = updateBytes(in: pdu)
        XCTAssertEqual(update.first! & 0x0F, FastPathOutput.updatePointer)
        XCTAssertEqual(readU16(update, at: 15), 128)
        XCTAssertEqual(readU16(update, at: 17), 3_072)
    }

    func testPointerUsesNewPointerFormatThrough96Pixels() {
        let pdu = FastPathOutput.pointer(
            cacheIndex: 3,
            hotspotX: 4,
            hotspotY: 5,
            width: 48,
            height: 48,
            xorMask: [UInt8](repeating: 0x11, count: 6_912),
            andMask: [UInt8](repeating: 0x22, count: 288)
        )

        let update = updateBytes(in: pdu)
        XCTAssertEqual(update.first! & 0x0F, FastPathOutput.updatePointer)
        XCTAssertEqual(readU16(update, at: 15), 288)
        XCTAssertEqual(readU16(update, at: 17), 6_912)
    }

    func testPointerUsesLargeFormatAbove96Pixels() {
        let pdu = FastPathOutput.pointer(
            cacheIndex: 3,
            hotspotX: 4,
            hotspotY: 5,
            width: 100,
            height: 100,
            xorMask: [UInt8](repeating: 0x11, count: 30_000),
            andMask: [UInt8](repeating: 0x22, count: 1_400)
        )

        let update = updateBytes(in: pdu)
        XCTAssertEqual(update.first! & 0x0F, FastPathOutput.updateLargePointer)
        XCTAssertEqual(readU32(update, at: 15), 1_400)
        XCTAssertEqual(readU32(update, at: 19), 30_000)
    }

    private func updateBytes(in pdu: [UInt8]) -> ArraySlice<UInt8> {
        let headerLength = pdu[1] & 0x80 == 0 ? 2 : 3
        return pdu[headerLength...]
    }

    private func readU16(_ bytes: ArraySlice<UInt8>, at offset: Int) -> UInt16 {
        let start = bytes.startIndex + offset
        return UInt16(bytes[start]) | UInt16(bytes[start + 1]) << 8
    }

    private func readU32(_ bytes: ArraySlice<UInt8>, at offset: Int) -> UInt32 {
        let start = bytes.startIndex + offset
        return UInt32(bytes[start])
            | UInt32(bytes[start + 1]) << 8
            | UInt32(bytes[start + 2]) << 16
            | UInt32(bytes[start + 3]) << 24
    }
}
