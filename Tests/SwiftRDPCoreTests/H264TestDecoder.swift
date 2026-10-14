import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import XCTest

/// Decode the actual Annex-B wire payload, retaining the client's reference chain.
final class H264TestDecoder {
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private let ready = DispatchSemaphore(value: 0)
        private var status: OSStatus = noErr
        private var buffer: CVPixelBuffer?

        func complete(status: OSStatus, buffer: CVPixelBuffer?) {
            lock.withLock { self.status = status; self.buffer = buffer }
            ready.signal()
        }

        func wait() throws -> CVPixelBuffer {
            XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
            return try lock.withLock {
                XCTAssertEqual(status, noErr)
                return try XCTUnwrap(buffer)
            }
        }
    }

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    func decode(_ bytes: [UInt8]) throws -> CVPixelBuffer {
        let starts = (0..<max(bytes.count - 3, 0)).filter {
            bytes[$0..<$0 + 4].elementsEqual([0, 0, 0, 1])
        }
        let units = starts.enumerated().map { index, start in
            Array(bytes[(start + 4)..<(index + 1 < starts.count ? starts[index + 1] : bytes.count)])
        }
        if units.contains(where: { $0.first.map { $0 & 0x1f == 7 } == true }) {
            let sps = try XCTUnwrap(units.first { $0.first.map { $0 & 0x1f == 7 } == true })
            let pps = try XCTUnwrap(units.first { $0.first.map { $0 & 0x1f == 8 } == true })
            let status = sps.withUnsafeBufferPointer { sps in
                pps.withUnsafeBufferPointer { pps in
                    let pointers = [sps.baseAddress!, pps.baseAddress!]
                    let sizes = [sps.count, pps.count]
                    return pointers.withUnsafeBufferPointer { pointers in
                        sizes.withUnsafeBufferPointer { sizes in
                            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                                allocator: nil, parameterSetCount: 2,
                                parameterSetPointers: pointers.baseAddress!,
                                parameterSetSizes: sizes.baseAddress!, nalUnitHeaderLength: 4,
                                formatDescriptionOut: &format)
                        }
                    }
                }
            }
            XCTAssertEqual(status, noErr)
            if let session, !VTDecompressionSessionCanAcceptFormatDescription(session,
                formatDescription: try XCTUnwrap(format)) {
                XCTAssertTrue(units.contains { $0.first.map { $0 & 0x1f == 5 } == true },
                    "a decoder format reset must carry an IDR, not depend on discarded references")
                VTDecompressionSessionInvalidate(session)
                self.session = nil
            }
            if session == nil {
                let attributes = [kCVPixelBufferPixelFormatTypeKey:
                    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] as CFDictionary
                XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil,
                    formatDescription: try XCTUnwrap(format), decoderSpecification: nil,
                    imageBufferAttributes: attributes, outputCallback: nil,
                    decompressionSessionOut: &session), noErr)
            }
        }

        var avcc = Data()
        for unit in units where unit.first.map({ [1, 5].contains($0 & 0x1f) }) == true {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(contentsOf: unit)
        }
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil,
            blockLength: avcc.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block), noErr)
        let dataBuffer = try XCTUnwrap(block)
        XCTAssertEqual(avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: dataBuffer,
                offsetIntoDestination: 0, dataLength: avcc.count)
        }, noErr)
        var sample: CMSampleBuffer?
        var size = avcc.count
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: nil, dataBuffer: dataBuffer,
            formatDescription: try XCTUnwrap(format), sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
        let output = Output()
        XCTAssertEqual(VTDecompressionSessionDecodeFrame(
            try XCTUnwrap(session), sampleBuffer: try XCTUnwrap(sample), flags: [], infoFlagsOut: nil
        ) { status, _, buffer, _, _ in
            output.complete(status: status, buffer: buffer)
        }, noErr)
        return try output.wait()
    }
}
