import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import XCTest
@testable import SwiftRDPCore

final class H264RefinementTests: XCTestCase {
    func testBudgetedStaticReferenceRefreshImprovesDecodedText() throws {
        let width = 1024, height = 768, updates = 24, shift = 11
        let sourceHeight = height + updates * shift
        var source = [UInt8](repeating: 24, count: width * sourceHeight)
        source.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: sourceHeight,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            let font = CTFontCreateWithName("Menlo" as CFString, 13, nil)
            for row in 0..<(sourceHeight / 18) {
                let code = String(repeating: "let value_\(row) = table[index + 1]; // encode pixels 0123456789  ", count: 5)
                let text = NSAttributedString(string: code, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.9, alpha: 1)
                ])
                context.textPosition = CGPoint(x: 5, y: row * 18 + 3)
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
        }
        var optionalBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &optionalBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(optionalBuffer)
        let encoder = H264Encoder()
        encoder.bitrate = 2_000_000
        encoder.expectedFrameRate = 60
        try encoder.start(width: width, height: height)
        defer { encoder.stop() }
        let decoder = H264TestDecoder()
        var lastDecoded: CVPixelBuffer?
        for index in 0..<updates {
            CVPixelBufferLockBaseAddress(buffer, [])
            let yBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            source.withUnsafeBytes { bytes in
                for y in 0..<height {
                    memcpy(yBase.advanced(by: y * yStride),
                        bytes.baseAddress!.advanced(by: (y + index * shift) * width), width)
                }
            }
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 1), 128,
                CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * height / 2)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            if let unit = try encode(encoder, buffer: buffer) {
                lastDecoded = try decoder.decode(unit.bytes)
            }
            Thread.sleep(forTimeInterval: 1.0 / 60)
        }
        // Retry the final source if native rate control dropped it, just as the
        // desktop scheduler does without requiring another capture publication.
        let final = try XCTUnwrap(try encode(encoder, buffer: buffer))
        lastDecoded = try decoder.decode(final.bytes)
        let before = lumaMSE(reference: buffer, decoded: try XCTUnwrap(lastDecoded))
        let nativeBefore = try XCTUnwrap(final.meanSquaredError)
        XCTAssertGreaterThan(before, 0.1, "fixture must exercise lossy text encoding")
        Thread.sleep(forTimeInterval: 0.25)
        // A real adaptive/user budget increase must improve the already static
        // reference without claiming extra capacity from an idle connection.
        let candidate = H264Encoder()
        candidate.bitrate = 20_000_000
        candidate.expectedFrameRate = 60
        try candidate.start(width: width, height: height)
        defer { candidate.stop() }
        var refinementBytes = 0
        for _ in 0..<AVCFrameScheduler.maxRefinementAttempts {
            if let unit = try encode(candidate, buffer: buffer, refinement: true) {
                XCTAssertTrue(unit.isIDR)
                XCTAssertLessThan(try XCTUnwrap(unit.meanSquaredError), nativeBefore * 0.9)
                refinementBytes += unit.bytes.count
                lastDecoded = try decoder.decode(unit.bytes)
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let after = lumaMSE(reference: buffer, decoded: try XCTUnwrap(lastDecoded))
        print("H264 text refinement: luma MSE \(before) -> \(after), bytes=\(refinementBytes)")
        XCTAssertLessThan(after, before * 0.9, "bounded refresh must improve decoded text, not merely resend it")
        XCTAssertLessThanOrEqual(refinementBytes,
            AVCFrameScheduler.refinementByteLimit(bitrate: candidate.bitrate))
    }

    private func encode(_ encoder: H264Encoder, buffer: CVPixelBuffer,
                        refinement: Bool = false) throws -> H264Encoder.EncodedAccessUnit? {
        let completed = DispatchSemaphore(value: 0)
        var result: Result<H264Encoder.EncodedAccessUnit, H264Encoder.EncodeError>?
        XCTAssertTrue(encoder.encodeAsync(pixelBuffer: buffer, refinement: refinement) {
            result = $0
            completed.signal()
        })
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        switch try XCTUnwrap(result) {
        case .success(let unit): return unit
        case .failure(.frameDropped): return nil
        case .failure(let error): throw error
        }
    }

    private func lumaMSE(reference: CVPixelBuffer, decoded: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(reference, .readOnly)
        CVPixelBufferLockBaseAddress(decoded, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(decoded, .readOnly)
            CVPixelBufferUnlockBaseAddress(reference, .readOnly)
        }
        let expected = CVPixelBufferGetBaseAddressOfPlane(reference, 0)!.assumingMemoryBound(to: UInt8.self)
        let actual = CVPixelBufferGetBaseAddressOfPlane(decoded, 0)!.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(reference), height = CVPixelBufferGetHeight(reference)
        let expectedStride = CVPixelBufferGetBytesPerRowOfPlane(reference, 0)
        let actualStride = CVPixelBufferGetBytesPerRowOfPlane(decoded, 0)
        var squaredError: UInt64 = 0
        for y in 0..<height {
            for x in 0..<width {
                let difference = Int(expected[y * expectedStride + x]) - Int(actual[y * actualStride + x])
                squaredError += UInt64(difference * difference)
            }
        }
        return Double(squaredError) / Double(width * height)
    }
}
