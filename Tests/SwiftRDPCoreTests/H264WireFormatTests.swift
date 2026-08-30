import CoreVideo
import XCTest
import VideoToolbox
@testable import SwiftRDPCore

final class H264WireFormatTests: XCTestCase {
    func testAVC420UsesFullRangeForScreenCaptureNV12() throws {
        let fullRange = try encodeAVC420(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        XCTAssertEqual(try XCTUnwrap(spsColorInfo(in: fullRange.bytes)).fullRange, true)
    }

    func testDiagnosticAVC420RangeSamples() throws {
        for value in [0, 16, 64, 128, 192, 235, 255] {
            let encoder = H264Encoder()
            encoder.asyncMode = false
            try encoder.start(width: 64, height: 64)
            defer { encoder.stop() }
            let encoded = try XCTUnwrap(
                encoder.encode(pixelBuffer: try makeNV12(
                    width: 64, height: 64,
                    pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                    luma: UInt8(value)
                ))
            )
            try Data(encoded.bytes).write(
                to: URL(fileURLWithPath: "/tmp/swiftrdp-range-\(value).h264")
            )
        }
    }

    func testAVC420IDRCarriesSPSAndCodesAtTheVisibleSize() throws {
        let encoder = H264Encoder()
        encoder.asyncMode = false
        try encoder.start(width: 320, height: 180)
        defer { encoder.stop() }

        let buffer = try makeBGRA(width: 320, height: 180)
        let encoded = try XCTUnwrap(encoder.encode(pixelBuffer: buffer))
        let types = nalTypes(in: encoded.bytes)
        XCTAssertTrue(encoded.isIDR)
        XCTAssertTrue(types.contains(5), "expected IDR, got \(types)")
        XCTAssertTrue(types.contains(7), "expected SPS, got \(types)")
        // SEI / AUD never reach the wire.
        XCTAssertFalse(types.contains(6))
        XCTAssertFalse(types.contains(9))
        // AVC420 codes at exactly the visible size; the SPS cropping window
        // handles the 180 rows that are not a multiple of 16.
        XCTAssertEqual(encoder.visibleWidth, 320)
        XCTAssertEqual(encoder.visibleHeight, 180)
        XCTAssertEqual(encoder.width, 320)
        XCTAssertEqual(encoder.height, 180)
    }

    func testAVC420UsesHighProfile() throws {
        let encoder = H264Encoder()
        encoder.asyncMode = false
        try encoder.start(width: 320, height: 192)
        defer { encoder.stop() }

        let buffer = try makeBGRA(width: 320, height: 192)
        let encoded = try XCTUnwrap(encoder.encode(pixelBuffer: buffer))
        let profile = try XCTUnwrap(spsProfile(in: encoded.bytes))
        XCTAssertEqual(profile, 100)
    }

    func testEncoderEmitsOnlyExplicitIDRs() throws {
        let encoder = H264Encoder()
        encoder.asyncMode = false
        encoder.expectedFrameRate = 30
        try encoder.start(width: 64, height: 64)
        defer { encoder.stop() }

        let buffer = try makeBGRA(width: 64, height: 64)
        var idrCount = 0
        for _ in 0..<40 {
            let encoded = try XCTUnwrap(encoder.encode(pixelBuffer: buffer))
            if encoded.isIDR { idrCount += 1 }
        }
        XCTAssertEqual(idrCount, 1)

        encoder.requestForceKeyframe()
        let forced = try XCTUnwrap(encoder.encode(pixelBuffer: buffer))
        XCTAssertTrue(forced.isIDR)
    }

    func testH264FrameRateStaysWithinLevel52Throughput() {
        XCTAssertEqual(
            H264Encoder.constrainedFrameRate(
                60, width: 3840, height: 2400
            ),
            55
        )
        XCTAssertEqual(
            H264Encoder.constrainedFrameRate(
                60, width: 3840, height: 2160
            ),
            60
        )
    }

    func testDataRateLimitConvertsBitsPerSecondToBytesPerSecond() {
        XCTAssertEqual(
            H264Encoder.dataRateLimitBytesPerSecond(forBitrate: 50_000_000),
            8_437_500
        )
    }

    func testVideoToolboxFrameDropFlagIsClassifiedSeparately() {
        XCTAssertTrue(H264Encoder.isFrameDropped(.frameDropped))
        XCTAssertFalse(H264Encoder.isFrameDropped(VTEncodeInfoFlags(rawValue: 0)))
    }

    private func makeBGRA(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0x40, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func encodeAVC420(pixelFormat: OSType) throws -> H264Encoder.EncodedAccessUnit {
        let encoder = H264Encoder()
        encoder.asyncMode = false
        try encoder.start(width: 64, height: 64)
        defer { encoder.stop() }
        return try XCTUnwrap(encoder.encode(pixelBuffer: try makeNV12(width: 64, height: 64, pixelFormat: pixelFormat)))
    }

    private func makeNV12(
        width: Int, height: Int, pixelFormat: OSType, luma: UInt8 = 128
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, pixelFormat,
                [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        let buffer = try XCTUnwrap(pixelBuffer)
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCMFormatDescriptionExtension_FullRangeVideo,
            pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                ? kCFBooleanTrue
                : kCFBooleanFalse,
            .shouldPropagate
        )
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            memset(yBase, Int32(luma), CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * height)
        }
        if let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            memset(uvBase, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * (height / 2))
        }
        return buffer
    }

    private func nalTypes(in bytes: [UInt8]) -> [UInt8] {
        var types: [UInt8] = []
        var index = 0
        while index + 3 < bytes.count {
            let codeLen: Int
            if index + 4 <= bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 0, bytes[index + 3] == 1 {
                codeLen = 4
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                codeLen = 3
            } else {
                index += 1
                continue
            }
            let header = index + codeLen
            guard header < bytes.count else { break }
            types.append(bytes[header] & 0x1F)
            index = header + 1
        }
        return types
    }

    private func spsProfile(in bytes: [UInt8]) -> UInt8? {
        var index = 0
        while index + 3 < bytes.count {
            let codeLen: Int
            if index + 4 <= bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 0, bytes[index + 3] == 1 {
                codeLen = 4
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                codeLen = 3
            } else {
                index += 1
                continue
            }
            let header = index + codeLen
            guard header + 1 < bytes.count else { break }
            if bytes[header] & 0x1F == 7 {
                return bytes[header + 1]
            }
            index = header + 1
        }
        return nil
    }

    private struct SPSColorInfo {
        let fullRange: Bool
    }

    private func spsColorInfo(in bytes: [UInt8]) -> SPSColorInfo? {
        guard let sps = nalPayload(type: 7, in: bytes) else { return nil }
        var reader = BitReader(bytes: removeEmulationPrevention(from: Array(sps.dropFirst())))
        guard reader.readBits(8) != nil,
              reader.readBits(8) != nil,
              reader.readBits(8) != nil,
              reader.readUE() != nil else { return nil }

        guard sps.count > 1 else { return nil }
        let profile = sps[sps.index(after: sps.startIndex)]
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(Int(profile)) {
            guard let chromaFormat = reader.readUE() else { return nil }
            if chromaFormat == 3 { guard reader.readBit() != nil else { return nil } }
            guard reader.readUE() != nil,
                  reader.readUE() != nil,
                  reader.readBit() != nil,
                  skipScalingMatrixIfPresent(&reader) else { return nil }
        }

        guard reader.readUE() != nil,
              let picOrderType = reader.readUE() else { return nil }
        if picOrderType == 0 {
            guard reader.readUE() != nil else { return nil }
        } else if picOrderType == 1 {
            guard reader.readBit() != nil,
                  reader.readSE() != nil,
                  reader.readSE() != nil,
                  let cycle = reader.readUE() else { return nil }
            for _ in 0..<cycle {
                guard reader.readSE() != nil else { return nil }
            }
        }
        guard reader.readUE() != nil,
              reader.readBit() != nil,
              reader.readUE() != nil,
              reader.readUE() != nil,
              let frameOnly = reader.readBit() else { return nil }
        if frameOnly == 0, reader.readBit() == nil { return nil }
        guard reader.readBit() != nil else { return nil }
        if let cropped = reader.readBit(), cropped != 0 {
            guard reader.readUE() != nil,
                  reader.readUE() != nil,
                  reader.readUE() != nil,
                  reader.readUE() != nil else { return nil }
        }
        guard let vuiPresent = reader.readBit(), vuiPresent != 0 else { return nil }
        guard let aspectPresent = reader.readBit() else { return nil }
        if aspectPresent != 0 {
            guard let aspectID = reader.readBits(8) else { return nil }
            if aspectID == 255 {
                guard reader.readBits(16) != nil, reader.readBits(16) != nil else { return nil }
            }
        }
        if let overscanPresent = reader.readBit(), overscanPresent != 0 {
            guard reader.readBit() != nil else { return nil }
        }
        guard let signalPresent = reader.readBit(), signalPresent != 0 else { return nil }
        guard reader.readBits(3) != nil,
              let fullRange = reader.readBit() else { return nil }
        return SPSColorInfo(fullRange: fullRange != 0)
    }

    private func skipScalingMatrixIfPresent(_ reader: inout BitReader) -> Bool {
        guard let present = reader.readBit() else { return false }
        guard present != 0 else { return true }
        for index in 0..<8 {
            guard let scalingPresent = reader.readBit() else { return false }
            guard scalingPresent != 0 else { continue }
            let size = index < 6 ? 16 : 64
            var lastScale = 8
            var nextScale = 8
            for _ in 0..<size {
                if nextScale != 0 {
                    guard let delta = reader.readSE() else { return false }
                    nextScale = (lastScale + delta + 256) % 256
                }
                lastScale = nextScale == 0 ? lastScale : nextScale
            }
        }
        return true
    }

    private func nalPayload(type: UInt8, in bytes: [UInt8]) -> ArraySlice<UInt8>? {
        var index = 0
        while index + 3 < bytes.count {
            let codeLength: Int
            if index + 4 <= bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 0, bytes[index + 3] == 1 {
                codeLength = 4
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                codeLength = 3
            } else {
                index += 1
                continue
            }
            let start = index + codeLength
            var end = start
            while end + 3 < bytes.count,
                  !(bytes[end] == 0 && bytes[end + 1] == 0 &&
                    (bytes[end + 2] == 1 || (bytes[end + 2] == 0 && bytes[end + 3] == 1))) {
                end += 1
            }
            if start < bytes.count, bytes[start] & 0x1F == type {
                return bytes[start..<end]
            }
            index = end
        }
        return nil
    }

    private func removeEmulationPrevention(from bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var zeroCount = 0
        for byte in bytes {
            if zeroCount >= 2, byte == 3 {
                zeroCount = 0
                continue
            }
            output.append(byte)
            zeroCount = byte == 0 ? zeroCount + 1 : 0
        }
        return output
    }

    private struct BitReader {
        let bytes: [UInt8]
        var offset = 0

        mutating func readBit() -> Int? {
            guard offset < bytes.count * 8 else { return nil }
            let bit = Int((bytes[offset / 8] >> (7 - (offset % 8))) & 1)
            offset += 1
            return bit
        }

        mutating func readBits(_ count: Int) -> Int? {
            guard count >= 0 else { return nil }
            var value = 0
            for _ in 0..<count {
                guard let bit = readBit() else { return nil }
                value = (value << 1) | bit
            }
            return value
        }

        mutating func readUE() -> Int? {
            var zeros = 0
            while true {
                guard let bit = readBit() else { return nil }
                if bit != 0 { break }
                zeros += 1
                guard zeros < 32 else { return nil }
            }
            guard let suffix = readBits(zeros) else { return nil }
            return (1 << zeros) - 1 + suffix
        }

        mutating func readSE() -> Int? {
            guard let code = readUE() else { return nil }
            return code.isMultiple(of: 2) ? -(code / 2) : (code + 1) / 2
        }
    }
}
