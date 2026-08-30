import AppKit
import Foundation
import XCTest
@testable import SwiftRDPCore

final class ClipboardSyncTests: XCTestCase {
    func testMacFileServesLockedDescriptorSizeAndRangeAfterLocalClipboardChanges() throws {
        let root = try makeTemporaryDirectory()
        let oldFile = root.appendingPathComponent("old.txt")
        let newFile = root.appendingPathComponent("new.txt")
        try Data("hello".utf8).write(to: oldFile)
        try Data("new".utf8).write(to: newFile)

        let sink = PacketSink()
        let clipboard = ClipboardSync(
            stagingRoot: root.appendingPathComponent("staging"),
            monitorSystemPasteboard: false,
            remoteContentPublisher: { _ in -1 }
        )
        clipboard.send = sink.append
        clipboard.onOpen(channelId: 1006)
        clipboard.startHandshakeIfNeeded()
        _ = try waitForPacket(.capabilities, in: sink)
        _ = try waitForPacket(.monitorReady, in: sink)

        clipboard.onData(ClipboardWire.makeCapabilitiesPDU())
        clipboard.updateLocalClipboard(
            .init(changeCount: 1, fileURLs: [oldFile], text: nil, html: nil, imageTIFF: nil)
        )
        _ = try waitForPacket(.formatList, in: sink)
        clipboard.onData(
            ClipboardWire.makePDU(type: .formatListResponse, flags: ClipboardWire.responseOK)
        )

        clipboard.onData(ClipboardWire.makeClipDataPDU(type: .lockClipData, id: 77))
        clipboard.onData(formatDataRequest(ClipboardWire.Format.fileGroupDescriptor))
        let descriptorResponse = try parse(
            waitForPacket(.formatDataResponse, in: sink),
            expected: .formatDataResponse
        )
        XCTAssertEqual(descriptorResponse.flags, ClipboardWire.responseOK)
        let descriptors = try XCTUnwrap(ClipboardWire.parseFileList(descriptorResponse.body))
        XCTAssertEqual(descriptors.map(\.relativePath), ["old.txt"])
        XCTAssertEqual(descriptors[0].size, 5)

        clipboard.updateLocalClipboard(
            .init(changeCount: 2, fileURLs: [newFile], text: nil, html: nil, imageTIFF: nil)
        )
        _ = try waitForPacket(.formatList, in: sink)

        clipboard.onData(
            ClipboardWire.makeFileContentsRequest(
                streamID: 10,
                listIndex: 0,
                flags: ClipboardWire.FileContentsFlag.size,
                offset: 0,
                requestedBytes: 8,
                clipDataID: 77
            )
        )
        let sizeResponse = try parse(
            waitForPacket(.fileContentsResponse, in: sink),
            expected: .fileContentsResponse
        )
        XCTAssertEqual(sizeResponse.flags, ClipboardWire.responseOK)
        XCTAssertEqual(ClipboardWire.readU32(sizeResponse.body, 0), 10)
        XCTAssertEqual(ClipboardWire.readU64(sizeResponse.body, 4), 5)

        clipboard.onData(
            ClipboardWire.makeFileContentsRequest(
                streamID: 11,
                listIndex: 0,
                flags: ClipboardWire.FileContentsFlag.range,
                offset: 0,
                requestedBytes: 32,
                clipDataID: 77
            )
        )
        let rangeResponse = try parse(
            waitForPacket(.fileContentsResponse, in: sink),
            expected: .fileContentsResponse
        )
        XCTAssertEqual(rangeResponse.flags, ClipboardWire.responseOK)
        XCTAssertEqual(ClipboardWire.readU32(rangeResponse.body, 0), 11)
        XCTAssertEqual(String(bytes: rangeResponse.body.dropFirst(4), encoding: .utf8), "hello")

        clipboard.onData(
            ClipboardWire.makeFileContentsRequest(
                streamID: 12,
                listIndex: 0,
                flags: ClipboardWire.FileContentsFlag.range,
                offset: 5,
                requestedBytes: 32,
                clipDataID: 77
            )
        )
        let eofResponse = try parse(
            waitForPacket(.fileContentsResponse, in: sink),
            expected: .fileContentsResponse
        )
        XCTAssertEqual(eofResponse.flags, ClipboardWire.responseOK)
        XCTAssertEqual(eofResponse.body, ClipboardWire.bytes(12))

        clipboard.onClose()
    }

    func testWindowsFilesStayLazyUntilPasteboardURLIsRead() throws {
        let root = try makeTemporaryDirectory()
        let sink = PacketSink()
        let publication = PublicationSink()
        let published = expectation(description: "remote files published")
        let clipboard = ClipboardSync(
            stagingRoot: root.appendingPathComponent("staging"),
            monitorSystemPasteboard: false,
            remoteContentPublisher: { content in
                publication.store(content)
                published.fulfill()
                return 42
            }
        )
        clipboard.send = sink.append
        clipboard.onOpen(channelId: 1006)
        clipboard.startHandshakeIfNeeded()
        _ = try waitForPacket(.capabilities, in: sink)
        _ = try waitForPacket(.monitorReady, in: sink)
        clipboard.onData(ClipboardWire.makeCapabilitiesPDU())

        let remoteFileListID: UInt32 = 0xD120
        clipboard.onData(
            ClipboardWire.makeFormatListPDU(
                [
                    .init(
                        id: remoteFileListID,
                        name: ClipboardWire.Format.fileGroupDescriptorName
                    ),
                    .init(id: 0xD121, name: ClipboardWire.Format.fileContentsName),
                ],
                longNames: true
            )
        )

        let listResponse = try parse(
            waitForPacket(.formatListResponse, in: sink),
            expected: .formatListResponse
        )
        XCTAssertEqual(listResponse.flags, ClipboardWire.responseOK)
        let lock = try parse(waitForPacket(.lockClipData, in: sink), expected: .lockClipData)
        let clipDataID = ClipboardWire.readU32(lock.body, 0)
        let formatRequest = try parse(
            waitForPacket(.formatDataRequest, in: sink),
            expected: .formatDataRequest
        )
        XCTAssertEqual(ClipboardWire.readU32(formatRequest.body, 0), remoteFileListID)

        let descriptors: [ClipboardWire.FileDescriptor] = [
            .init(relativePath: "资料", isDirectory: true, size: nil, modifiedAt: nil),
            .init(relativePath: "资料\\hello.txt", isDirectory: false, size: 5, modifiedAt: nil),
        ]
        clipboard.onData(
            ClipboardWire.makeFormatDataResponse(
                body: ClipboardWire.packFileList(descriptors),
                success: true
            )
        )

        wait(for: [published], timeout: 2)
        guard case .files(let promise) = publication.content else {
            return XCTFail("expected a remote file promise")
        }
        XCTAssertEqual(promise.topLevelNames, ["资料"])
        XCTAssertNil(sink.take(.fileContentsRequest), "copying metadata must not download file contents")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("staging"),
                includingPropertiesForKeys: nil
            ).count,
            0
        )

        let resolved = expectation(description: "remote file promise resolved")
        let resolution = URLSink()
        DispatchQueue.global().async {
            resolution.store(promise.resolveTopLevel(named: "资料"))
            resolved.fulfill()
        }

        let sizeRequestPDU = try parse(
            waitForPacket(.fileContentsRequest, in: sink),
            expected: .fileContentsRequest
        )
        let sizeRequest = try XCTUnwrap(ClipboardWire.parseFileContentsRequest(sizeRequestPDU.body))
        XCTAssertEqual(sizeRequest.listIndex, 1)
        XCTAssertEqual(sizeRequest.flags, ClipboardWire.FileContentsFlag.size)
        XCTAssertEqual(sizeRequest.clipDataID, clipDataID)

        clipboard.onData(
            ClipboardWire.makeFileContentsResponse(
                streamID: sizeRequest.streamID,
                data: littleEndianBytes(5),
                success: true
            )
        )
        let rangeRequestPDU = try parse(
            waitForPacket(.fileContentsRequest, in: sink),
            expected: .fileContentsRequest
        )
        let rangeRequest = try XCTUnwrap(ClipboardWire.parseFileContentsRequest(rangeRequestPDU.body))
        XCTAssertEqual(rangeRequest.flags, ClipboardWire.FileContentsFlag.range)
        XCTAssertEqual(rangeRequest.offset, 0)
        XCTAssertEqual(rangeRequest.requestedBytes, 5)
        XCTAssertEqual(rangeRequest.clipDataID, clipDataID)

        clipboard.onData(
            ClipboardWire.makeFileContentsResponse(
                streamID: rangeRequest.streamID,
                data: Array("hello".utf8),
                success: true
            )
        )
        wait(for: [resolved], timeout: 2)

        let url = try XCTUnwrap(resolution.url)
        XCTAssertEqual(url.lastPathComponent, "资料")
        XCTAssertEqual(
            try String(contentsOf: url.appendingPathComponent("hello.txt"), encoding: .utf8),
            "hello"
        )
        XCTAssertEqual(promise.resolveTopLevel(named: "资料"), url)
        XCTAssertNil(sink.take(.fileContentsRequest), "resolved promises must reuse the staged file")

        let unlock = try parse(waitForPacket(.unlockClipData, in: sink), expected: .unlockClipData)
        XCTAssertEqual(ClipboardWire.readU32(unlock.body, 0), clipDataID)
        clipboard.onClose()
    }

    func testPasteboardBridgeDefersFileURLMaterializationUntilRead() throws {
        let root = try makeTemporaryDirectory()
        let file = root.appendingPathComponent("remote.txt")
        let starts = Counter()
        let promise = try ClipboardRemoteFilePromise(
            descriptors: [
                .init(relativePath: "remote.txt", isDirectory: false, size: 5, modifiedAt: nil),
            ]
        ) { promise in
            starts.increment()
            try? Data("hello".utf8).write(to: file)
            promise.complete(with: [file])
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        let changeCount = ClipboardPasteboardBridge.publish(.files(promise), to: pasteboard)

        XCTAssertEqual(starts.value, 0)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.types, [.fileURL])

        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]

        XCTAssertEqual(starts.value, 1)
        XCTAssertEqual(pasteboard.changeCount, changeCount)
        XCTAssertEqual(urls, [file])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hello")
    }

    func testWindowsDIBV5ClipboardImageRequestsAndPublishesTIFF() throws {
        let sink = PacketSink()
        let publication = PublicationSink()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = ClipboardSync(
            stagingRoot: nil,
            monitorSystemPasteboard: false,
            remoteContentPublisher: { content in
                publication.store(content)
                return ClipboardPasteboardBridge.publish(content, to: pasteboard)
            }
        )
        clipboard.send = sink.append
        try open(clipboard, sink: sink)

        clipboard.onData(
            ClipboardWire.makeFormatListPDU(
                [.init(id: ClipboardWire.Format.dibV5, name: nil)],
                longNames: true
            )
        )
        _ = try waitForPacket(.formatListResponse, in: sink)
        let request = try parse(waitForPacket(.formatDataRequest, in: sink), expected: .formatDataRequest)
        XCTAssertEqual(ClipboardWire.readU32(request.body, 0), ClipboardWire.Format.dibV5)

        let dib = makeDIBV5Pixel(red: 0x12, green: 0x34, blue: 0x56)
        clipboard.onData(ClipboardWire.makeFormatDataResponse(body: dib, success: true))

        let image = try waitForImage(in: publication)
        XCTAssertTrue(pasteboard.types?.contains(.tiff) == true)
        XCTAssertEqual(pasteboard.data(forType: .tiff), image.tiffRepresentation)
        XCTAssertNotNil(ClipboardPasteboardBridge.capture(pasteboard).imageTIFF)
        clipboard.onClose()
    }

    func testWindowsImageTakesPriorityOverTextAndHTML() throws {
        let sink = PacketSink()
        let publication = PublicationSink()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = ClipboardSync(
            stagingRoot: nil,
            monitorSystemPasteboard: false,
            remoteContentPublisher: { content in
                publication.store(content)
                return ClipboardPasteboardBridge.publish(content, to: pasteboard)
            }
        )
        clipboard.send = sink.append
        try open(clipboard, sink: sink)

        clipboard.onData(
            ClipboardWire.makeFormatListPDU(
                [
                    .init(id: ClipboardWire.Format.unicodeText, name: nil),
                    .init(id: ClipboardWire.Format.html, name: ClipboardWire.Format.htmlName),
                    .init(id: ClipboardWire.Format.dibV5, name: nil),
                ],
                longNames: true
            )
        )
        _ = try waitForPacket(.formatListResponse, in: sink)
        let request = try parse(waitForPacket(.formatDataRequest, in: sink), expected: .formatDataRequest)
        XCTAssertEqual(ClipboardWire.readU32(request.body, 0), ClipboardWire.Format.dibV5)

        clipboard.onData(
            ClipboardWire.makeFormatDataResponse(
                body: makeDIBV5Pixel(red: 0x12, green: 0x34, blue: 0x56),
                success: true
            )
        )

        let image = try waitForImage(in: publication)
        XCTAssertEqual(pasteboard.data(forType: .tiff), image.tiffRepresentation)
        clipboard.onClose()
    }

    func testWindowsUnicodeTextTakesPriorityOverHTML() throws {
        let sink = PacketSink()
        let publication = PublicationSink()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = ClipboardSync(
            stagingRoot: nil,
            monitorSystemPasteboard: false,
            remoteContentPublisher: { content in
                publication.store(content)
                return ClipboardPasteboardBridge.publish(content, to: pasteboard)
            }
        )
        clipboard.send = sink.append
        try open(clipboard, sink: sink)

        clipboard.onData(
            ClipboardWire.makeFormatListPDU(
                [
                    .init(id: ClipboardWire.Format.html, name: ClipboardWire.Format.htmlName),
                    .init(id: ClipboardWire.Format.unicodeText, name: nil),
                ],
                longNames: true
            )
        )
        _ = try waitForPacket(.formatListResponse, in: sink)
        let request = try parse(waitForPacket(.formatDataRequest, in: sink), expected: .formatDataRequest)
        XCTAssertEqual(ClipboardWire.readU32(request.body, 0), ClipboardWire.Format.unicodeText)

        let expected = "差异审阅单元已生成，但完整单元清单超过当前返回上限。"
        clipboard.onData(
            ClipboardWire.makeFormatDataResponse(
                body: ClipboardWire.encodeUnicodeText(expected),
                success: true
            )
        )

        XCTAssertEqual(try waitForText(in: publication), expected)
        XCTAssertEqual(pasteboard.string(forType: .string), expected)
        clipboard.onClose()
    }

    func testMacClipboardImageAnnouncesOnlyDIBV5AndServesIt() throws {
        let sink = PacketSink()
        let clipboard = ClipboardSync(
            stagingRoot: nil,
            monitorSystemPasteboard: false,
            remoteContentPublisher: { _ in -1 }
        )
        clipboard.send = sink.append
        try open(clipboard, sink: sink)

        let tiff = try makeTestTIFF()
        clipboard.updateLocalClipboard(
            .init(changeCount: 1, fileURLs: [], text: nil, html: nil, imageTIFF: tiff)
        )

        let formatList = try parse(waitForPacket(.formatList, in: sink), expected: .formatList)
        let formats = try XCTUnwrap(
            ClipboardWire.parseFormatList(formatList.body, longNames: true, asciiShortNames: false)
        )
        XCTAssertEqual(formats.ids, [ClipboardWire.Format.dibV5])

        clipboard.onData(ClipboardWire.makePDU(type: .formatListResponse, flags: ClipboardWire.responseOK))
        clipboard.onData(ClipboardWire.makeFormatDataRequest(ClipboardWire.Format.dibV5))
        let response = try parse(waitForPacket(.formatDataResponse, in: sink), expected: .formatDataResponse)
        XCTAssertEqual(response.flags, ClipboardWire.responseOK)
        XCTAssertNotNil(ClipboardImageCodec.decodeDIBV5(response.body))
        clipboard.onClose()
    }

    func testRapidRemoteCopiesDiscardTheOlderDescriptorResponse() throws {
        let root = try makeTemporaryDirectory()
        let sink = PacketSink()
        let publication = PublicationSink()
        let clipboard = ClipboardSync(
            stagingRoot: root.appendingPathComponent("staging"),
            monitorSystemPasteboard: false,
            remoteContentPublisher: { content in
                publication.store(content)
                return 20
            }
        )
        clipboard.send = sink.append
        try open(clipboard, sink: sink)

        clipboard.onData(remoteFileFormatList(descriptorID: 0xD400))
        _ = try waitForPacket(.formatListResponse, in: sink)
        let oldLock = try parse(waitForPacket(.lockClipData, in: sink), expected: .lockClipData)
        let oldRequest = try parse(waitForPacket(.formatDataRequest, in: sink), expected: .formatDataRequest)
        XCTAssertEqual(ClipboardWire.readU32(oldRequest.body, 0), 0xD400)

        clipboard.onData(remoteFileFormatList(descriptorID: 0xD500))
        _ = try waitForPacket(.formatListResponse, in: sink)
        let oldUnlock = try parse(waitForPacket(.unlockClipData, in: sink), expected: .unlockClipData)
        XCTAssertEqual(oldUnlock.body, oldLock.body)
        _ = try waitForPacket(.lockClipData, in: sink)
        XCTAssertNil(sink.take(.formatDataRequest), "the new request must wait for the untagged old response")

        clipboard.onData(
            ClipboardWire.makeFormatDataResponse(
                body: ClipboardWire.packFileList([
                    .init(relativePath: "old.bin", isDirectory: false, size: 3, modifiedAt: nil),
                ]),
                success: true
            )
        )

        let newRequest = try parse(waitForPacket(.formatDataRequest, in: sink), expected: .formatDataRequest)
        XCTAssertEqual(ClipboardWire.readU32(newRequest.body, 0), 0xD500)
        XCTAssertNil(publication.takeFilePromise())

        clipboard.onData(
            ClipboardWire.makeFormatDataResponse(
                body: ClipboardWire.packFileList([
                    .init(relativePath: "new.bin", isDirectory: false, size: 3, modifiedAt: nil),
                ]),
                success: true
            )
        )

        let promise = try waitForFilePromise(in: publication)
        XCTAssertEqual(promise.topLevelNames, ["new.bin"])
        XCTAssertNil(sink.take(.fileContentsRequest))
        clipboard.onClose()
    }

    func testRemoteClipboardChangeWaitsForActivePasteToFinish() throws {
        let root = try makeTemporaryDirectory()
        let sink = PacketSink()
        let publication = PublicationSink()
        let clipboard = ClipboardSync(
            stagingRoot: root.appendingPathComponent("staging"),
            monitorSystemPasteboard: false,
            remoteContentPublisher: { content in
                publication.store(content)
                return 30
            }
        )
        clipboard.send = sink.append
        try open(clipboard, sink: sink)

        clipboard.onData(remoteFileFormatList(descriptorID: 0xD600))
        _ = try waitForPacket(.formatListResponse, in: sink)
        let oldLock = try parse(waitForPacket(.lockClipData, in: sink), expected: .lockClipData)
        _ = try waitForPacket(.formatDataRequest, in: sink)
        clipboard.onData(
            ClipboardWire.makeFormatDataResponse(
                body: ClipboardWire.packFileList([
                    .init(relativePath: "old.bin", isDirectory: false, size: 3, modifiedAt: nil),
                ]),
                success: true
            )
        )

        let oldPromise = try waitForFilePromise(in: publication)
        let oldResolved = expectation(description: "active old paste completed")
        let oldResolution = URLSink()
        DispatchQueue.global().async {
            oldResolution.store(oldPromise.resolveTopLevel(named: "old.bin"))
            oldResolved.fulfill()
        }
        let sizeRequest = try XCTUnwrap(
            ClipboardWire.parseFileContentsRequest(
                try parse(waitForPacket(.fileContentsRequest, in: sink), expected: .fileContentsRequest).body
            )
        )

        clipboard.onData(remoteFileFormatList(descriptorID: 0xD700))
        _ = try waitForPacket(.formatListResponse, in: sink)
        XCTAssertNil(sink.take(.unlockClipData))
        XCTAssertNil(sink.take(.lockClipData))
        XCTAssertNil(sink.take(.formatDataRequest))

        clipboard.onData(
            ClipboardWire.makeFileContentsResponse(
                streamID: sizeRequest.streamID,
                data: littleEndianBytes(3),
                success: true
            )
        )
        let rangeRequest = try XCTUnwrap(
            ClipboardWire.parseFileContentsRequest(
                try parse(waitForPacket(.fileContentsRequest, in: sink), expected: .fileContentsRequest).body
            )
        )
        clipboard.onData(
            ClipboardWire.makeFileContentsResponse(
                streamID: rangeRequest.streamID,
                data: Array("old".utf8),
                success: true
            )
        )
        wait(for: [oldResolved], timeout: 2)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(oldResolution.url), encoding: .utf8), "old")

        let oldUnlock = try parse(waitForPacket(.unlockClipData, in: sink), expected: .unlockClipData)
        XCTAssertEqual(oldUnlock.body, oldLock.body)
        let newLock = try parse(waitForPacket(.lockClipData, in: sink), expected: .lockClipData)
        XCTAssertNotEqual(newLock.body, oldLock.body)
        let newRequest = try parse(waitForPacket(.formatDataRequest, in: sink), expected: .formatDataRequest)
        XCTAssertEqual(ClipboardWire.readU32(newRequest.body, 0), 0xD700)

        clipboard.onData(
            ClipboardWire.makeFormatDataResponse(
                body: ClipboardWire.packFileList([
                    .init(relativePath: "new.bin", isDirectory: false, size: 3, modifiedAt: nil),
                ]),
                success: true
            )
        )
        XCTAssertEqual(try waitForFilePromise(in: publication).topLevelNames, ["new.bin"])
        XCTAssertNil(sink.take(.fileContentsRequest))
        clipboard.onClose()
    }

    func testLocalCopyDoesNotCancelAnActiveRemotePaste() throws {
        let root = try makeTemporaryDirectory()
        let sink = PacketSink()
        let publication = PublicationSink()
        let clipboard = ClipboardSync(
            stagingRoot: root.appendingPathComponent("staging"),
            monitorSystemPasteboard: false,
            remoteContentPublisher: { content in
                publication.store(content)
                return 31
            }
        )
        clipboard.send = sink.append
        try open(clipboard, sink: sink)
        clipboard.updateLocalClipboard(
            .init(changeCount: 1, fileURLs: [], text: "initial", html: nil, imageTIFF: nil)
        )
        _ = try waitForPacket(.formatList, in: sink)
        clipboard.onData(ClipboardWire.makePDU(type: .formatListResponse, flags: ClipboardWire.responseOK))

        clipboard.onData(remoteFileFormatList(descriptorID: 0xD800))
        _ = try waitForPacket(.formatListResponse, in: sink)
        let lock = try parse(waitForPacket(.lockClipData, in: sink), expected: .lockClipData)
        _ = try waitForPacket(.formatDataRequest, in: sink)
        clipboard.onData(
            ClipboardWire.makeFormatDataResponse(
                body: ClipboardWire.packFileList([
                    .init(relativePath: "remote.bin", isDirectory: false, size: 3, modifiedAt: nil),
                ]),
                success: true
            )
        )
        let promise = try waitForFilePromise(in: publication)
        let resolved = expectation(description: "remote paste survived local copy")
        let resolution = URLSink()
        DispatchQueue.global().async {
            resolution.store(promise.resolveTopLevel(named: "remote.bin"))
            resolved.fulfill()
        }
        let sizeRequest = try XCTUnwrap(
            ClipboardWire.parseFileContentsRequest(
                try parse(waitForPacket(.fileContentsRequest, in: sink), expected: .fileContentsRequest).body
            )
        )

        clipboard.updateLocalClipboard(
            .init(changeCount: 2, fileURLs: [], text: "new", html: nil, imageTIFF: nil)
        )
        _ = try waitForPacket(.formatList, in: sink)
        XCTAssertNil(sink.take(.unlockClipData))

        clipboard.onData(
            ClipboardWire.makeFileContentsResponse(
                streamID: sizeRequest.streamID,
                data: littleEndianBytes(3),
                success: true
            )
        )
        let rangeRequest = try XCTUnwrap(
            ClipboardWire.parseFileContentsRequest(
                try parse(waitForPacket(.fileContentsRequest, in: sink), expected: .fileContentsRequest).body
            )
        )
        clipboard.onData(
            ClipboardWire.makeFileContentsResponse(
                streamID: rangeRequest.streamID,
                data: Array("rdp".utf8),
                success: true
            )
        )
        wait(for: [resolved], timeout: 2)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(resolution.url), encoding: .utf8), "rdp")
        XCTAssertEqual(
            try parse(waitForPacket(.unlockClipData, in: sink), expected: .unlockClipData).body,
            lock.body
        )
        clipboard.onClose()
    }

    func testInvalidFileRangeRequestReturnsFailureWithOriginalStreamID() throws {
        let root = try makeTemporaryDirectory()
        let file = root.appendingPathComponent("file.bin")
        try Data([1, 2, 3]).write(to: file)
        let sink = PacketSink()
        let clipboard = ClipboardSync(
            stagingRoot: root.appendingPathComponent("staging"),
            monitorSystemPasteboard: false,
            remoteContentPublisher: { _ in -1 }
        )
        clipboard.send = sink.append
        clipboard.onOpen(channelId: 1006)
        clipboard.startHandshakeIfNeeded()
        _ = try waitForPacket(.capabilities, in: sink)
        _ = try waitForPacket(.monitorReady, in: sink)
        clipboard.onData(ClipboardWire.makeCapabilitiesPDU())
        clipboard.updateLocalClipboard(
            .init(changeCount: 1, fileURLs: [file], text: nil, html: nil, imageTIFF: nil)
        )
        _ = try waitForPacket(.formatList, in: sink)
        clipboard.onData(
            ClipboardWire.makePDU(type: .formatListResponse, flags: ClipboardWire.responseOK)
        )

        clipboard.onData(
            ClipboardWire.makeFileContentsRequest(
                streamID: 123,
                listIndex: 0,
                flags: ClipboardWire.FileContentsFlag.size | ClipboardWire.FileContentsFlag.range,
                offset: 0,
                requestedBytes: 3,
                clipDataID: nil
            )
        )
        let response = try parse(
            waitForPacket(.fileContentsResponse, in: sink),
            expected: .fileContentsResponse
        )
        XCTAssertEqual(response.flags, ClipboardWire.responseFail)
        XCTAssertEqual(response.body, ClipboardWire.bytes(123))
        clipboard.onClose()
    }

    func testReplacementCancelsAnUnconsumedFilePromise() throws {
        let root = try makeTemporaryDirectory()
        let sink = PacketSink()
        let publication = PublicationSink()
        let clipboard = ClipboardSync(
            stagingRoot: root.appendingPathComponent("staging"),
            monitorSystemPasteboard: false,
            remoteContentPublisher: { content in
                publication.store(content)
                return 10
            }
        )
        clipboard.send = sink.append
        try open(clipboard, sink: sink)

        clipboard.onData(remoteFileFormatList(descriptorID: 0xD100))
        _ = try waitForPacket(.formatListResponse, in: sink)
        let firstLock = try parse(waitForPacket(.lockClipData, in: sink), expected: .lockClipData)
        _ = try waitForPacket(.formatDataRequest, in: sink)
        clipboard.onData(
            ClipboardWire.makeFormatDataResponse(
                body: ClipboardWire.packFileList([
                    .init(relativePath: "old.bin", isDirectory: false, size: 7, modifiedAt: nil),
                ]),
                success: true
            )
        )
        let oldPromise = try waitForFilePromise(in: publication)
        XCTAssertNil(sink.take(.fileContentsRequest))

        clipboard.onData(remoteFileFormatList(descriptorID: 0xD200))
        _ = try waitForPacket(.formatListResponse, in: sink)
        let firstUnlock = try parse(waitForPacket(.unlockClipData, in: sink), expected: .unlockClipData)
        XCTAssertEqual(firstUnlock.body, firstLock.body)
        XCTAssertNil(oldPromise.resolveTopLevel(named: "old.bin"))
        let secondLock = try parse(waitForPacket(.lockClipData, in: sink), expected: .lockClipData)
        XCTAssertNotEqual(secondLock.body, firstLock.body)
        _ = try waitForPacket(.formatDataRequest, in: sink)

        clipboard.onData(
            ClipboardWire.makeFormatDataResponse(
                body: ClipboardWire.packFileList([
                    .init(relativePath: "new.bin", isDirectory: false, size: 3, modifiedAt: nil),
                ]),
                success: true
            )
        )
        let newPromise = try waitForFilePromise(in: publication)
        XCTAssertEqual(newPromise.topLevelNames, ["new.bin"])
        XCTAssertNil(sink.take(.fileContentsRequest))
        clipboard.onClose()
    }

    func testStaleFileResponseDoesNotDisableActiveRequestTimeout() throws {
        let root = try makeTemporaryDirectory()
        let stagingRoot = root.appendingPathComponent("staging")
        let sink = PacketSink()
        let publication = PublicationSink()
        let clipboard = ClipboardSync(
            stagingRoot: stagingRoot,
            monitorSystemPasteboard: false,
            remoteContentPublisher: { content in
                publication.store(content)
                return -1
            },
            requestTimeout: 0.2
        )
        clipboard.send = sink.append
        try open(clipboard, sink: sink)

        clipboard.onData(remoteFileFormatList(descriptorID: 0xD280))
        _ = try waitForPacket(.formatListResponse, in: sink)
        let lock = try parse(waitForPacket(.lockClipData, in: sink), expected: .lockClipData)
        _ = try waitForPacket(.formatDataRequest, in: sink)
        clipboard.onData(
            ClipboardWire.makeFormatDataResponse(
                body: ClipboardWire.packFileList([
                    .init(relativePath: "waiting.bin", isDirectory: false, size: 1, modifiedAt: nil),
                ]),
                success: true
            )
        )
        let promise = try waitForFilePromise(in: publication)
        let resolved = expectation(description: "timed out promise failed")
        let resolution = URLSink()
        DispatchQueue.global().async {
            resolution.store(promise.resolveTopLevel(named: "waiting.bin"))
            resolved.fulfill()
        }
        let sizeRequest = try XCTUnwrap(
            ClipboardWire.parseFileContentsRequest(
                try parse(
                    waitForPacket(.fileContentsRequest, in: sink),
                    expected: .fileContentsRequest
                ).body
            )
        )
        clipboard.onData(
            ClipboardWire.makeFileContentsResponse(
                streamID: sizeRequest.streamID &+ 1_000,
                data: littleEndianBytes(1),
                success: true
            )
        )

        let unlock = try parse(
            waitForPacket(.unlockClipData, in: sink, timeout: 1),
            expected: .unlockClipData
        )
        XCTAssertEqual(unlock.body, lock.body)
        wait(for: [resolved], timeout: 1)
        XCTAssertNil(resolution.url)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil).count,
            0
        )
        clipboard.onClose()
    }

    func testInvalidRemoteFileListDoesNotLeakStagingDirectory() throws {
        let root = try makeTemporaryDirectory()
        let stagingRoot = root.appendingPathComponent("staging")
        let sink = PacketSink()
        let clipboard = ClipboardSync(
            stagingRoot: stagingRoot,
            monitorSystemPasteboard: false,
            remoteContentPublisher: { _ in -1 }
        )
        clipboard.send = sink.append
        try open(clipboard, sink: sink)

        clipboard.onData(remoteFileFormatList(descriptorID: 0xD300))
        _ = try waitForPacket(.formatListResponse, in: sink)
        _ = try waitForPacket(.lockClipData, in: sink)
        _ = try waitForPacket(.formatDataRequest, in: sink)
        clipboard.onData(
            ClipboardWire.makeFormatDataResponse(
                body: ClipboardWire.packFileList([
                    .init(relativePath: "..\\escape.bin", isDirectory: false, size: 1, modifiedAt: nil),
                ]),
                success: true
            )
        )
        _ = try waitForPacket(.unlockClipData, in: sink)

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil).count,
            0
        )
        clipboard.onClose()
    }

    func testChannelReopenClearsPendingFormatListState() throws {
        let root = try makeTemporaryDirectory()
        let sink = PacketSink()
        let clipboard = ClipboardSync(
            stagingRoot: root.appendingPathComponent("staging"),
            monitorSystemPasteboard: false,
            remoteContentPublisher: { _ in -1 }
        )
        clipboard.send = sink.append
        try open(clipboard, sink: sink)
        clipboard.updateLocalClipboard(
            .init(changeCount: 1, fileURLs: [], text: "first", html: nil, imageTIFF: nil)
        )
        _ = try waitForPacket(.formatList, in: sink)

        clipboard.onClose()
        clipboard.onOpen(channelId: 1007)
        clipboard.startHandshakeIfNeeded()
        _ = try waitForPacket(.capabilities, in: sink)
        _ = try waitForPacket(.monitorReady, in: sink)
        clipboard.onData(ClipboardWire.makeCapabilitiesPDU())
        clipboard.updateLocalClipboard(
            .init(changeCount: 2, fileURLs: [], text: "second", html: nil, imageTIFF: nil)
        )

        let formatList = try parse(waitForPacket(.formatList, in: sink), expected: .formatList)
        let formats = try XCTUnwrap(
            ClipboardWire.parseFormatList(formatList.body, longNames: true, asciiShortNames: false)
        )
        XCTAssertEqual(formats.ids, [ClipboardWire.Format.unicodeText])
        clipboard.onClose()
    }

    private final class PacketSink: @unchecked Sendable {
        private let lock = NSLock()
        private var packets: [[UInt8]] = []

        func append(_ packet: [UInt8]) {
            lock.lock()
            packets.append(packet)
            lock.unlock()
        }

        func take(_ type: ClipboardWire.MessageType) -> [UInt8]? {
            lock.lock()
            defer { lock.unlock() }
            guard let index = packets.firstIndex(where: { ClipboardWire.parsePDU($0)?.type == type }) else {
                return nil
            }
            return packets.remove(at: index)
        }
    }

    private final class PublicationSink: @unchecked Sendable {
        private let lock = NSLock()
        private var storedContents: [ClipboardRemoteContent] = []

        var content: ClipboardRemoteContent? {
            lock.lock()
            defer { lock.unlock() }
            return storedContents.last
        }

        func store(_ content: ClipboardRemoteContent) {
            lock.lock()
            storedContents.append(content)
            lock.unlock()
        }

        func takeFilePromise() -> ClipboardRemoteFilePromise? {
            lock.lock()
            defer { lock.unlock() }
            guard let index = storedContents.firstIndex(where: {
                if case .files = $0 { return true }
                return false
            }) else { return nil }
            guard case .files(let promise) = storedContents.remove(at: index) else { return nil }
            return promise
        }
    }

    private final class URLSink: @unchecked Sendable {
        private let lock = NSLock()
        private var storedURL: URL?

        var url: URL? {
            lock.lock()
            defer { lock.unlock() }
            return storedURL
        }

        func store(_ url: URL?) {
            lock.lock()
            storedURL = url
            lock.unlock()
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    private func open(_ clipboard: ClipboardSync, sink: PacketSink) throws {
        clipboard.onOpen(channelId: 1006)
        clipboard.startHandshakeIfNeeded()
        _ = try waitForPacket(.capabilities, in: sink)
        _ = try waitForPacket(.monitorReady, in: sink)
        clipboard.onData(ClipboardWire.makeCapabilitiesPDU())
    }

    private func remoteFileFormatList(descriptorID: UInt32) -> [UInt8] {
        ClipboardWire.makeFormatListPDU(
            [
                .init(id: descriptorID, name: ClipboardWire.Format.fileGroupDescriptorName),
                .init(id: descriptorID + 1, name: ClipboardWire.Format.fileContentsName),
            ],
            longNames: true
        )
    }

    private func waitForPacket(
        _ type: ClipboardWire.MessageType,
        in sink: PacketSink,
        timeout: TimeInterval = 2
    ) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let packet = sink.take(type) { return packet }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        XCTFail("timed out waiting for clipboard PDU \(type)")
        throw ClipboardFileTransferError.invalidResponse
    }

    private func waitForFilePromise(
        in publication: PublicationSink,
        timeout: TimeInterval = 2
    ) throws -> ClipboardRemoteFilePromise {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let promise = publication.takeFilePromise() { return promise }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        XCTFail("timed out waiting for remote file promise")
        throw ClipboardFileTransferError.invalidResponse
    }

    private func waitForImage(
        in publication: PublicationSink,
        timeout: TimeInterval = 2
    ) throws -> NSImage {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let content = publication.content, case .image(let image) = content {
                return image
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        XCTFail("timed out waiting for remote image")
        throw ClipboardFileTransferError.invalidResponse
    }

    private func waitForText(
        in publication: PublicationSink,
        timeout: TimeInterval = 2
    ) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let content = publication.content, case .text(let text) = content {
                return text
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        XCTFail("timed out waiting for remote text")
        throw ClipboardFileTransferError.invalidResponse
    }

    private func makeDIBV5Pixel(red: UInt8, green: UInt8, blue: UInt8) -> [UInt8] {
        var dib = [UInt8](repeating: 0, count: 128)
        writeU32(&dib, 0, 124)
        writeU32(&dib, 4, 1)
        writeU32(&dib, 8, 1)
        writeU16(&dib, 12, 1)
        writeU16(&dib, 14, 32)
        writeU32(&dib, 16, 3)
        writeU32(&dib, 20, 4)
        writeU32(&dib, 40, 0x00FF0000)
        writeU32(&dib, 44, 0x0000FF00)
        writeU32(&dib, 48, 0x000000FF)
        writeU32(&dib, 52, 0xFF000000)
        writeU32(&dib, 56, 0x73524742)
        writeU32(&dib, 124, UInt32(blue) | UInt32(green) << 8 | UInt32(red) << 16 | 0xFF000000)
        return dib
    }

    private func makeTestTIFF() throws -> Data {
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

    private func writeU16(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt16) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8(value >> 8)
    }

    private func writeU32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 3] = UInt8(value >> 24)
    }

    private func parse(
        _ packet: [UInt8],
        expected type: ClipboardWire.MessageType
    ) throws -> ClipboardWire.PDU {
        let pdu = try XCTUnwrap(ClipboardWire.parsePDU(packet))
        XCTAssertEqual(pdu.type, type)
        return pdu
    }

    private func formatDataRequest(_ formatID: UInt32) -> [UInt8] {
        ClipboardWire.makePDU(type: .formatDataRequest, body: ClipboardWire.bytes(formatID))
    }

    private func littleEndianBytes(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftRDP-ClipboardSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
