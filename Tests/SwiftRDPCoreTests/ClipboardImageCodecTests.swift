import AppKit
import Foundation
import XCTest
@testable import SwiftRDPCore

final class ClipboardImageCodecTests: XCTestCase {
    func testDIBV5RoundTripUses32BitBitFieldsAndPreservesPixels() throws {
        let sourceTIFF = try makeKnownTIFF()
        let dib = try XCTUnwrap(ClipboardImageCodec.encodeDIBV5(tiff: sourceTIFF))

        XCTAssertEqual(readU32(dib, 0), 124)
        XCTAssertEqual(readU16(dib, 14), 32)
        XCTAssertEqual(readU32(dib, 16), 3)
        XCTAssertEqual(readU32(dib, 40), 0x00FF0000)
        XCTAssertEqual(readU32(dib, 44), 0x0000FF00)
        XCTAssertEqual(readU32(dib, 48), 0x000000FF)
        XCTAssertEqual(readU32(dib, 52), 0xFF000000)
        XCTAssertEqual(dib.count, 124 + 16)

        XCTAssertEqual(Array(dib.suffix(16)), [
            255, 0, 0, 255, 255, 255, 255, 255,
            0, 0, 255, 255, 0, 255, 0, 255,
        ])
    }

    func testDIBV5EncodingPreservesImageCoordinates() throws {
        let dib = try XCTUnwrap(ClipboardImageCodec.encodeDIBV5(tiff: makeKnownTIFF()))
        let decoded = try XCTUnwrap(ClipboardImageCodec.decodeDIBV5(dib))
        let representation = try XCTUnwrap(decoded.representations.first as? NSBitmapImageRep)
        assertColor(representation, at: (0, 0), equals: color(1, 0, 0))
        assertColor(representation, at: (1, 0), equals: color(0, 1, 0))
        assertColor(representation, at: (0, 1), equals: color(0, 0, 1))
        assertColor(representation, at: (1, 1), equals: color(1, 1, 1))
    }

    func testDIBV5DecodesBottomUpRows() throws {
        let dib = makeDIBV5(
            width: 2,
            height: 2,
            pixels: [
                0xFFFF0000, 0xFFFFFFFF,
                0xFF0000FF, 0xFF00FF00,
            ]
        )

        let decoded = try XCTUnwrap(ClipboardImageCodec.decodeDIBV5(dib))
        let representation = try XCTUnwrap(decoded.representations.first as? NSBitmapImageRep)
        assertColor(representation, at: (0, 0), equals: color(0, 0, 1))
        assertColor(representation, at: (1, 0), equals: color(0, 1, 0))
        assertColor(representation, at: (0, 1), equals: color(1, 0, 0))
        assertColor(representation, at: (1, 1), equals: color(1, 1, 1))
    }

    func testDIBV5DecodesBIRGBWithImplicitImageSize() throws {
        let dib = makeDIBV5(
            width: 2,
            height: 2,
            compression: 0,
            imageSize: 0,
            alphaMask: 0,
            pixels: [
                0xFFFF0000, 0xFFFFFFFF,
                0xFF0000FF, 0xFF00FF00,
            ]
        )

        let decoded = try XCTUnwrap(ClipboardImageCodec.decodeDIBV5(dib))
        let representation = try XCTUnwrap(decoded.representations.first as? NSBitmapImageRep)
        assertColor(representation, at: (0, 0), equals: color(0, 0, 1))
        assertColor(representation, at: (1, 0), equals: color(0, 1, 0))
        assertColor(representation, at: (0, 1), equals: color(1, 0, 0))
        assertColor(representation, at: (1, 1), equals: color(1, 1, 1))
    }

    private func makeKnownTIFF() throws -> Data {
        let representation = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [.thirtyTwoBitLittleEndian, .alphaNonpremultiplied],
            bytesPerRow: 8,
            bitsPerPixel: 32
        ))
        let bitmap = try XCTUnwrap(representation.bitmapData)
        let pixels: [UInt8] = [
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 255, 255,
        ]
        for index in pixels.indices {
            bitmap[index] = pixels[index]
        }
        return try XCTUnwrap(representation.tiffRepresentation)
    }

    private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
    }

    private func makeDIBV5(
        width: Int,
        height: Int32,
        compression: UInt32 = 3,
        imageSize: UInt32? = nil,
        alphaMask: UInt32 = 0xFF000000,
        pixels: [UInt32]
    ) -> [UInt8] {
        var dib: [UInt8] = []
        dib.reserveCapacity(124 + pixels.count * 4)
        appendU32(&dib, 124)
        appendU32(&dib, UInt32(width))
        appendU32(&dib, UInt32(bitPattern: height))
        appendU16(&dib, 1)
        appendU16(&dib, 32)
        appendU32(&dib, compression)
        appendU32(&dib, imageSize ?? UInt32(pixels.count * 4))
        appendU32(&dib, 0)
        appendU32(&dib, 0)
        appendU32(&dib, 0)
        appendU32(&dib, 0)
        appendU32(&dib, 0x00FF0000)
        appendU32(&dib, 0x0000FF00)
        appendU32(&dib, 0x000000FF)
        appendU32(&dib, alphaMask)
        appendU32(&dib, 0x73524742)
        for _ in 0..<16 {
            appendU32(&dib, 0)
        }
        for pixel in pixels {
            appendU32(&dib, pixel)
        }
        return dib
    }

    private func assertColor(
        _ representation: NSBitmapImageRep,
        at point: (x: Int, y: Int),
        equals expected: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = representation.colorAt(x: point.x, y: point.y)?.usingColorSpace(.deviceRGB)
        XCTAssertEqual(actual?.redComponent ?? -1, expected.redComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual?.greenComponent ?? -1, expected.greenComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual?.blueComponent ?? -1, expected.blueComponent, accuracy: 0.01, file: file, line: line)
    }

    private func readU16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private func appendU16(_ bytes: inout [UInt8], _ value: UInt16) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8(value >> 8))
    }

    private func appendU32(_ bytes: inout [UInt8], _ value: UInt32) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8(value >> 24))
    }
}
