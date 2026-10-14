import CoreVideo
import Dispatch
import Foundation
import XCTest
@testable import SwiftRDPCore

final class H264RateControlTests: XCTestCase {
    func testBackpressureGapsDoNotInflateTheEncodedFrameBudget() throws {
        let width = 1920, height = 1080, frames = 40, shift = 11
        let sourceWidth = width + frames * shift
        let source = UnsafeMutablePointer<UInt32>.allocate(capacity: sourceWidth * height)
        defer { source.deallocate() }
        for y in 0..<height {
            for x in 0..<sourceWidth {
                let r = (x * 7 + y * 3) & 255
                let g = ((x / 11) * 53 + (y / 13) * 29) & 255
                let b = ((x / 31) ^ (y / 17)) * 37 & 255
                source[y * sourceWidth + x] = 0xff000000 | UInt32(r << 16 | g << 8 | b)
            }
        }
        var optionalBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &optionalBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(optionalBuffer)
        let encoder = H264Encoder()
        encoder.bitrate = 4_500_000
        encoder.expectedFrameRate = 30
        try encoder.start(width: width, height: height)
        defer { encoder.stop() }

        var sizes: [Int] = []
        for index in 0..<frames {
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                memcpy(base.advanced(by: y * stride),
                    source.advanced(by: y * sourceWidth + index * shift), width * 4)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let completed = DispatchSemaphore(value: 0)
            var result: Result<H264Encoder.EncodedAccessUnit, H264Encoder.EncodeError>?
            XCTAssertTrue(encoder.encodeAsync(pixelBuffer: buffer) { encoded in
                result = encoded
                completed.signal()
            })
            guard completed.wait(timeout: .now() + 2) == .success else {
                XCTFail("hardware encoder timed out")
                return
            }
            switch try XCTUnwrap(result) {
            case .success(let unit):
                if index >= 4, !unit.isIDR { sizes.append(unit.bytes.count) }
            case .failure(.frameDropped):
                break // Rate control may discard high-entropy source frames.
            case .failure(let error):
                XCTFail("hardware encode failed: \(error)")
                return
            }
            // Represents waiting for Graphics credit, rather than a change to
            // the requested picture cadence or available per-frame byte budget.
            Thread.sleep(forTimeInterval: 0.12)
        }
        XCTAssertGreaterThanOrEqual(sizes.count, 10)
        let average = Double(sizes.reduce(0, +)) / Double(max(sizes.count, 1))
        let frameBudget = Double(encoder.bitrate) / Double(encoder.expectedFrameRate) / 8
        XCTAssertLessThan(average, frameBudget * 2,
            "delivery gaps must not turn a 30-FPS budget into a low-FPS oversized frame budget")
    }
}
