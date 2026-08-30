import Foundation
import XCTest
@testable import SwiftRDPCore

final class ClipboardWireTests: XCTestCase {
    func testPDUAcceptsCurrentWindowsImagePayloadSize() throws {
        let body = [UInt8](repeating: 0, count: 28_000_000)
        let pdu = try XCTUnwrap(
            ClipboardWire.parsePDU(
                ClipboardWire.makePDU(type: .formatDataResponse, flags: ClipboardWire.responseOK, body: body)
            )
        )

        XCTAssertEqual(pdu.body.count, body.count)
    }

    func testCapabilitiesUseWindowsCompatibleFileClipboardFlags() throws {
        let pdu = try XCTUnwrap(ClipboardWire.parsePDU(ClipboardWire.makeCapabilitiesPDU()))
        XCTAssertEqual(pdu.type, .capabilities)

        let flags = ClipboardWire.readU32(pdu.body, 12)
        XCTAssertEqual(
            flags,
            ClipboardWire.Capability.useLongFormatNames
                | ClipboardWire.Capability.streamFileClip
                | ClipboardWire.Capability.noFilePaths
                | ClipboardWire.Capability.canLockClipData
        )
        XCTAssertEqual(flags & 0x0000_0020, 0) // CB_HUGE_FILE_SUPPORT_ENABLED

        let capabilities = try XCTUnwrap(ClipboardWire.parseCapabilities(pdu.body))
        XCTAssertTrue(capabilities.useLongFormatNames)
        XCTAssertTrue(capabilities.streamFileClip)
        XCTAssertTrue(capabilities.noFilePaths)
        XCTAssertTrue(capabilities.canLockClipData)
    }

    func testFileDescriptorWUsesProtocolOffsetsAndPreservesUnicode() throws {
        let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let relativePath = "资料\\报告-😀.txt"
        let size: UInt64 = 0x1122_3344_5566_7788
        let packed = ClipboardWire.packFileList([
            .init(
                relativePath: relativePath,
                isDirectory: false,
                size: size,
                modifiedAt: modifiedAt
            ),
        ])

        XCTAssertEqual(packed.count, 4 + ClipboardWire.fileDescriptorSize)
        XCTAssertEqual(ClipboardWire.readU32(packed, 0), 1)

        let descriptorOffset = 4
        let flags = ClipboardWire.readU32(packed, descriptorOffset)
        XCTAssertEqual(flags & 0x0000_0004, 0x0000_0004) // FD_ATTRIBUTES
        XCTAssertEqual(flags & 0x0000_0020, 0x0000_0020) // FD_WRITESTIME
        XCTAssertEqual(flags & 0x0000_0040, 0x0000_0040) // FD_FILESIZE
        XCTAssertEqual(flags & 0x8000_0000, 0x8000_0000) // FD_UNICODE
        XCTAssertTrue(packed[(descriptorOffset + 4)..<(descriptorOffset + 36)].allSatisfy { $0 == 0 })
        XCTAssertEqual(ClipboardWire.readU32(packed, descriptorOffset + 36), 0x80)
        XCTAssertTrue(packed[(descriptorOffset + 40)..<(descriptorOffset + 56)].allSatisfy { $0 == 0 })
        XCTAssertNotEqual(ClipboardWire.readU64(packed, descriptorOffset + 56), 0)
        XCTAssertEqual(ClipboardWire.readU32(packed, descriptorOffset + 64), 0x1122_3344)
        XCTAssertEqual(ClipboardWire.readU32(packed, descriptorOffset + 68), 0x5566_7788)

        var expectedNameBytes: [UInt8] = []
        for unit in relativePath.utf16 {
            expectedNameBytes.append(UInt8(unit & 0xFF))
            expectedNameBytes.append(UInt8(unit >> 8))
        }
        expectedNameBytes.append(contentsOf: [0, 0])
        let nameOffset = descriptorOffset + 72
        XCTAssertEqual(Array(packed[nameOffset..<(nameOffset + expectedNameBytes.count)]), expectedNameBytes)

        let decoded = try XCTUnwrap(ClipboardWire.parseFileList(packed))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].relativePath, relativePath)
        XCTAssertFalse(decoded[0].isDirectory)
        XCTAssertEqual(decoded[0].size, size)
        XCTAssertEqual(
            try XCTUnwrap(decoded[0].modifiedAt).timeIntervalSince1970,
            modifiedAt.timeIntervalSince1970,
            accuracy: 0.000_001
        )
    }

    func testRegisteredFormatIDsRemainEndpointLocal() throws {
        let localPacket = ClipboardWire.makeFormatListPDU(
            [
                .init(
                    id: ClipboardWire.Format.fileGroupDescriptor,
                    name: ClipboardWire.Format.fileGroupDescriptorName
                ),
                .init(id: ClipboardWire.Format.fileContents, name: ClipboardWire.Format.fileContentsName),
            ],
            longNames: true
        )
        let remoteDescriptorID: UInt32 = 0xD120
        let remoteContentsID: UInt32 = 0xD121
        let remotePacket = ClipboardWire.makeFormatListPDU(
            [
                .init(id: remoteDescriptorID, name: ClipboardWire.Format.fileGroupDescriptorName),
                .init(id: remoteContentsID, name: ClipboardWire.Format.fileContentsName),
            ],
            longNames: true
        )

        let localPDU = try XCTUnwrap(ClipboardWire.parsePDU(localPacket))
        let remotePDU = try XCTUnwrap(ClipboardWire.parsePDU(remotePacket))
        let localFormats = try XCTUnwrap(
            ClipboardWire.parseFormatList(localPDU.body, longNames: true, asciiShortNames: false)
        )
        let remoteFormats = try XCTUnwrap(
            ClipboardWire.parseFormatList(remotePDU.body, longNames: true, asciiShortNames: false)
        )

        XCTAssertEqual(
            localFormats.id(named: ClipboardWire.Format.fileGroupDescriptorName),
            ClipboardWire.Format.fileGroupDescriptor
        )
        XCTAssertEqual(
            remoteFormats.id(named: ClipboardWire.Format.fileGroupDescriptorName.lowercased()),
            remoteDescriptorID
        )
        XCTAssertEqual(remoteFormats.id(named: ClipboardWire.Format.fileContentsName), remoteContentsID)
        XCTAssertNotEqual(remoteDescriptorID, ClipboardWire.Format.fileGroupDescriptor)
        XCTAssertNotEqual(remoteContentsID, ClipboardWire.Format.fileContents)
    }

    func testFileContentsRequestParsesOnlyExact24Or28ByteBodies() throws {
        let withoutLock = ClipboardWire.makeFileContentsRequest(
            streamID: 0x0102_0304,
            listIndex: 7,
            flags: ClipboardWire.FileContentsFlag.range,
            offset: 0x1122_3344_5566_7788,
            requestedBytes: 0x0010_0000,
            clipDataID: nil
        )
        let withoutLockPDU = try XCTUnwrap(ClipboardWire.parsePDU(withoutLock))
        XCTAssertEqual(withoutLockPDU.body.count, 24)
        XCTAssertEqual(
            ClipboardWire.parseFileContentsRequest(withoutLockPDU.body),
            .init(
                streamID: 0x0102_0304,
                listIndex: 7,
                flags: ClipboardWire.FileContentsFlag.range,
                offset: 0x1122_3344_5566_7788,
                requestedBytes: 0x0010_0000,
                clipDataID: nil
            )
        )

        let withLock = ClipboardWire.makeFileContentsRequest(
            streamID: 99,
            listIndex: 2,
            flags: ClipboardWire.FileContentsFlag.size,
            offset: 0,
            requestedBytes: 8,
            clipDataID: 0xAABB_CCDD
        )
        let withLockPDU = try XCTUnwrap(ClipboardWire.parsePDU(withLock))
        XCTAssertEqual(withLockPDU.body.count, 28)
        XCTAssertEqual(ClipboardWire.parseFileContentsRequest(withLockPDU.body)?.clipDataID, 0xAABB_CCDD)

        for invalidLength in [0, 4, 23, 25, 27, 29] {
            XCTAssertNil(
                ClipboardWire.parseFileContentsRequest([UInt8](repeating: 0, count: invalidLength)),
                "accepted invalid request body length \(invalidLength)"
            )
        }
    }

    func testLocalFileSnapshotRecursesDirectoriesAndKeepsEmptyFiles() throws {
        let temporaryRoot = try makeTemporaryDirectory()
        let source = temporaryRoot.appendingPathComponent("folder", isDirectory: true)
        let emptyDirectory = source.appendingPathComponent("b-empty-dir", isDirectory: true)
        let nestedDirectory = source.appendingPathComponent("c-nested", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try Data().write(to: source.appendingPathComponent("a-empty.txt"))
        try Data([0x10, 0x20, 0x30]).write(to: nestedDirectory.appendingPathComponent("payload.bin"))

        let snapshot = try ClipboardLocalFileSnapshot.capture(urls: [source])
        let descriptors = snapshot.descriptors
        XCTAssertEqual(
            descriptors.map(\.relativePath),
            [
                "folder",
                "folder\\a-empty.txt",
                "folder\\b-empty-dir",
                "folder\\c-nested",
                "folder\\c-nested\\payload.bin",
            ]
        )
        XCTAssertTrue(descriptors[0].isDirectory)
        XCTAssertEqual(descriptors[1].size, 0)
        XCTAssertTrue(descriptors[2].isDirectory)
        XCTAssertNil(descriptors[2].size)
        XCTAssertTrue(descriptors[3].isDirectory)
        XCTAssertEqual(descriptors[4].size, 3)
        XCTAssertEqual(
            snapshot.files[4].sourceURL.resolvingSymlinksInPath(),
            nestedDirectory.appendingPathComponent("payload.bin").resolvingSymlinksInPath()
        )
    }

    func testLocalFileSnapshotRejectsInvalidRelativePath() throws {
        let temporaryRoot = try makeTemporaryDirectory()
        let invalidFile = temporaryRoot.appendingPathComponent("bad:name")
        try Data([0x01]).write(to: invalidFile)

        XCTAssertThrowsError(try ClipboardLocalFileSnapshot.capture(urls: [invalidFile])) { error in
            XCTAssertEqual(error as? ClipboardFileTransferError, .invalidPath("bad:name"))
        }
        XCTAssertThrowsError(try ClipboardPath.validate("folder\\..\\escape.txt")) { error in
            XCTAssertEqual(
                error as? ClipboardFileTransferError,
                .invalidPath("folder\\..\\escape.txt")
            )
        }
    }

    func testWindowsRDPFileSizeBoundaryIsEnforcedInBothDirections() throws {
        XCTAssertEqual(ClipboardTransferLimits.maximumFileSize, UInt64(Int32.max))

        let temporaryRoot = try makeTemporaryDirectory()
        let source = temporaryRoot.appendingPathComponent("boundary.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: ClipboardTransferLimits.maximumFileSize)
        try handle.close()

        let snapshot = try ClipboardLocalFileSnapshot.capture(urls: [source])
        XCTAssertEqual(snapshot.files.first?.descriptor.size, ClipboardTransferLimits.maximumFileSize)

        let oversizedHandle = try FileHandle(forWritingTo: source)
        try oversizedHandle.truncate(atOffset: ClipboardTransferLimits.maximumFileSize + 1)
        try oversizedHandle.close()
        XCTAssertThrowsError(try ClipboardLocalFileSnapshot.capture(urls: [source])) { error in
            XCTAssertEqual(error as? ClipboardFileTransferError, .fileTooLarge("boundary.bin"))
        }

        let oversizedDescriptor = ClipboardWire.FileDescriptor(
            relativePath: "remote.bin",
            isDirectory: false,
            size: ClipboardTransferLimits.maximumFileSize + 1,
            modifiedAt: nil
        )
        XCTAssertThrowsError(
            try ClipboardFileManifest(descriptors: [oversizedDescriptor])
        ) { error in
            XCTAssertEqual(error as? ClipboardFileTransferError, .fileTooLarge("remote.bin"))
        }

        let receiver = ClipboardFileReceiver(
            manifest: try ClipboardFileManifest(descriptors: [
                .init(relativePath: "unknown-size.bin", isDirectory: false, size: nil, modifiedAt: nil),
            ]),
            destinationRoot: temporaryRoot,
            streamIDs: ClipboardStreamIDAllocator()
        )
        let sizeRequest = try request(from: receiver.start())
        XCTAssertEqual(
            receiver.acceptResponse(
                streamID: sizeRequest.streamID,
                success: true,
                data: littleEndianBytes(ClipboardTransferLimits.maximumFileSize + 1)
            ),
            .failed(.fileTooLarge("unknown-size.bin"))
        )
    }

    func testFileReceiverHandlesSizeMultipleChunksEmptyFileAndCompletion() throws {
        let destination = try makeTemporaryDirectory()
        let largeSize = UInt64(ClipboardTransferLimits.chunkSize) + 3
        let descriptors: [ClipboardWire.FileDescriptor] = [
            .init(relativePath: "folder", isDirectory: true, size: nil, modifiedAt: nil),
            .init(relativePath: "folder\\large.bin", isDirectory: false, size: largeSize, modifiedAt: nil),
            .init(relativePath: "folder\\empty.txt", isDirectory: false, size: 0, modifiedAt: nil),
        ]
        let receiver = ClipboardFileReceiver(
            manifest: try ClipboardFileManifest(descriptors: descriptors),
            destinationRoot: destination,
            streamIDs: ClipboardStreamIDAllocator()
        )

        let sizeRequest = try request(from: receiver.start())
        XCTAssertEqual(sizeRequest, .init(streamID: 1, listIndex: 1, kind: .size))

        let firstRange = try request(
            from: receiver.acceptResponse(
                streamID: sizeRequest.streamID,
                success: true,
                data: littleEndianBytes(largeSize)
            )
        )
        XCTAssertEqual(
            firstRange,
            .init(
                streamID: 2,
                listIndex: 1,
                kind: .range(offset: 0, length: ClipboardTransferLimits.chunkSize)
            )
        )

        let firstChunk = [UInt8](repeating: 0xA5, count: Int(ClipboardTransferLimits.chunkSize))
        let secondRange = try request(
            from: receiver.acceptResponse(
                streamID: firstRange.streamID,
                success: true,
                data: firstChunk
            )
        )
        XCTAssertEqual(
            secondRange,
            .init(
                streamID: 3,
                listIndex: 1,
                kind: .range(offset: UInt64(ClipboardTransferLimits.chunkSize), length: 3)
            )
        )

        let emptySizeRequest = try request(
            from: receiver.acceptResponse(
                streamID: secondRange.streamID,
                success: true,
                data: [0x01, 0x02, 0x03]
            )
        )
        XCTAssertEqual(emptySizeRequest, .init(streamID: 4, listIndex: 2, kind: .size))

        let completion = receiver.acceptResponse(
            streamID: emptySizeRequest.streamID,
            success: true,
            data: littleEndianBytes(0)
        )
        guard case .completed(let topLevelURLs) = completion else {
            return XCTFail("expected completed event, got \(completion)")
        }
        XCTAssertEqual(topLevelURLs, [destination.appendingPathComponent("folder")])

        let largeFile = destination.appendingPathComponent("folder/large.bin")
        let written = try Data(contentsOf: largeFile)
        XCTAssertEqual(written.count, Int(largeSize))
        XCTAssertEqual(written.prefix(firstChunk.count), Data(firstChunk))
        XCTAssertEqual(Array(written.suffix(3)), [0x01, 0x02, 0x03])

        let emptyFile = destination.appendingPathComponent("folder/empty.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: emptyFile.path))
        XCTAssertEqual(try Data(contentsOf: emptyFile).count, 0)
    }

    func testFileReceiverFailsRemoteAndMismatchedResponses() throws {
        let descriptor = ClipboardWire.FileDescriptor(
            relativePath: "file.bin",
            isDirectory: false,
            size: 1,
            modifiedAt: nil
        )

        let remoteFailureReceiver = ClipboardFileReceiver(
            manifest: try ClipboardFileManifest(descriptors: [descriptor]),
            destinationRoot: try makeTemporaryDirectory(),
            streamIDs: ClipboardStreamIDAllocator()
        )
        let remoteRequest = try request(from: remoteFailureReceiver.start())
        XCTAssertEqual(
            remoteFailureReceiver.acceptResponse(
                streamID: remoteRequest.streamID,
                success: false,
                data: []
            ),
            .failed(.remoteFailure)
        )

        let mismatchedReceiver = ClipboardFileReceiver(
            manifest: try ClipboardFileManifest(descriptors: [descriptor]),
            destinationRoot: try makeTemporaryDirectory(),
            streamIDs: ClipboardStreamIDAllocator()
        )
        let expectedRequest = try request(from: mismatchedReceiver.start())
        XCTAssertEqual(
            mismatchedReceiver.acceptResponse(
                streamID: expectedRequest.streamID + 1,
                success: true,
                data: littleEndianBytes(1)
            ),
            .ignored
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftRDP-ClipboardWireTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func request(from event: ClipboardFileReceiver.Event) throws -> ClipboardFileReceiver.Request {
        guard case .request(let request) = event else {
            XCTFail("expected request event, got \(event)")
            throw ClipboardFileTransferError.invalidResponse
        }
        return request
    }

    private func littleEndianBytes(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }
}
