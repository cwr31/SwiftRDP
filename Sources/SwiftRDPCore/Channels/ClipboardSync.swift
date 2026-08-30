import AppKit
import Foundation

/// Bidirectional CLIPRDR endpoint with immutable local snapshots and an explicit
/// request state machine for remote content.
public final class ClipboardSync: VirtualChannel, @unchecked Sendable {
    public let name = "cliprdr"
    public var send: (([UInt8]) -> Void)?

    private enum PendingFormatRequest {
        case fileList
        case unicodeText
        case html
        case image
    }

    private struct RemoteFormatRequest {
        let formatID: UInt32
        let kind: PendingFormatRequest
        let generation: UUID
    }

    private let stateQueue = DispatchQueue(label: "app.swift-rdp.clipboard")
    private let stagingStore: ClipboardStagingStore
    private let inboundStreamIDs = ClipboardStreamIDAllocator()
    private let monitorSystemPasteboard: Bool
    private let remoteContentPublisher: (ClipboardRemoteContent) -> Int
    private let requestTimeout: TimeInterval

    private var channelID: UInt16 = 0
    private var handshakeSent = false
    private var sessionGeneration = UUID()
    private var remoteClipboardGeneration = UUID()

    private var remoteCapabilities: ClipboardWire.Capabilities?
    private var negotiatedLongNames = false
    private var negotiatedFileClip = false
    private var negotiatedLocking = false

    private var localSnapshot = ClipboardLocalSnapshot.empty
    private var localFiles: ClipboardLocalFileSnapshot?
    private var hasCapturedLocalClipboard = false
    private var announcedSnapshot = ClipboardLocalSnapshot.empty
    private var announcedFiles: ClipboardLocalFileSnapshot?
    private var announcedFormatsAccepted = false
    private var awaitingFormatListResponse = false
    private var localFormatsDirty = false
    private var lockedFileSnapshots: [UInt32: ClipboardLocalFileSnapshot] = [:]

    private var pendingFormatRequest: RemoteFormatRequest?
    private var queuedFormatRequest: RemoteFormatRequest?
    private var discardPendingFormatResponse = false
    private var deferredRemoteFormats: ClipboardWire.Formats?
    private var inboundPromise: ClipboardRemoteFilePromise?
    private var inboundReceiver: ClipboardFileReceiver?
    private var inboundDirectory: URL?
    private var inboundClipDataID: UInt32?
    private var nextClipDataID: UInt32 = 1
    private var requestEpoch: UInt64 = 0

    private var monitorTimer: DispatchSourceTimer?
    private var monitoredPasteboardChangeCount = -1
    private var observedPasteboardChangeCount = -1

    public convenience init() {
        self.init(
            stagingRoot: nil,
            monitorSystemPasteboard: true,
            remoteContentPublisher: { ClipboardPasteboardBridge.publish($0) },
            requestTimeout: ClipboardTransferLimits.requestTimeout
        )
    }

    init(
        stagingRoot: URL?,
        monitorSystemPasteboard: Bool,
        remoteContentPublisher: @escaping (ClipboardRemoteContent) -> Int,
        requestTimeout: TimeInterval = ClipboardTransferLimits.requestTimeout
    ) {
        self.stagingStore = ClipboardStagingStore(rootURL: stagingRoot)
        self.monitorSystemPasteboard = monitorSystemPasteboard
        self.remoteContentPublisher = remoteContentPublisher
        self.requestTimeout = requestTimeout
    }

    public func onOpen(channelId: UInt16) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.resetSessionState()
            self.channelID = channelId
            self.sessionGeneration = UUID()
            RDPLog.channels.info("Clipboard: channel open id=\(channelId)")
        }
    }

    public func startHandshakeIfNeeded() {
        stateQueue.async { [weak self] in
            guard let self, self.channelID != 0, !self.handshakeSent else { return }
            self.handshakeSent = true
            self.sendPacket(ClipboardWire.makeCapabilitiesPDU())
            self.sendPacket(ClipboardWire.makePDU(type: .monitorReady))
            RDPLog.channels.info("Clipboard: sent capabilities and monitor ready")
            self.startPasteboardMonitor(for: self.sessionGeneration)
        }
    }

    public func onData(_ data: [UInt8]) {
        stateQueue.async { [weak self] in
            self?.processPDU(data)
        }
    }

    public func onClose() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.deferredRemoteFormats = nil
            self.cancelInboundTransfer(reason: "channel closed")
            self.stopPasteboardMonitor()
            self.resetSessionState()
            self.sessionGeneration = UUID()
            RDPLog.channels.info("Clipboard: channel closed")
        }
    }

    func updateLocalClipboard(_ snapshot: ClipboardLocalSnapshot) {
        stateQueue.async { [weak self] in
            self?.acceptLocalClipboard(snapshot)
        }
    }

    private func processPDU(_ data: [UInt8]) {
        guard let pdu = ClipboardWire.parsePDU(data) else {
            RDPLog.channels.error("Clipboard: invalid PDU (\(data.count)B)")
            return
        }

        switch pdu.type {
        case .capabilities:
            handleCapabilities(pdu.body)
        case .temporaryDirectory:
            break
        case .formatList:
            handleRemoteFormatList(flags: pdu.flags, body: pdu.body)
        case .formatListResponse:
            handleFormatListResponse(flags: pdu.flags)
        case .formatDataRequest:
            handleFormatDataRequest(pdu.body)
        case .formatDataResponse:
            handleFormatDataResponse(flags: pdu.flags, body: pdu.body)
        case .lockClipData:
            handlePeerLock(pdu.body)
        case .unlockClipData:
            handlePeerUnlock(pdu.body)
        case .fileContentsRequest:
            handleFileContentsRequest(pdu.body)
        case .fileContentsResponse:
            handleFileContentsResponse(flags: pdu.flags, body: pdu.body)
        case .monitorReady:
            break
        }
    }

    // MARK: - Negotiation and format lists

    private func handleCapabilities(_ body: [UInt8]) {
        let capabilities = ClipboardWire.parseCapabilities(body) ?? .init(
            useLongFormatNames: false,
            streamFileClip: false,
            noFilePaths: false,
            canLockClipData: false
        )
        remoteCapabilities = capabilities
        negotiatedLongNames = capabilities.useLongFormatNames
        negotiatedFileClip = capabilities.streamFileClip
        negotiatedLocking = capabilities.canLockClipData
        RDPLog.channels.info(
            "Clipboard: negotiated longNames=\(negotiatedLongNames) files=\(negotiatedFileClip) "
                + "locking=\(negotiatedLocking)"
        )
        sendLatestLocalFormatListIfPossible()
    }

    private func handleRemoteFormatList(flags: UInt16, body: [UInt8]) {
        guard let formats = ClipboardWire.parseFormatList(
            body,
            longNames: negotiatedLongNames,
            asciiShortNames: flags & 0x0004 != 0
        ) else {
            sendPacket(ClipboardWire.makePDU(type: .formatListResponse, flags: ClipboardWire.responseFail))
            deferredRemoteFormats = nil
            if inboundReceiver == nil {
                remoteClipboardGeneration = UUID()
                cancelInboundTransfer(reason: "malformed remote clipboard")
                replaceRemoteFormatRequest(with: nil)
            }
            RDPLog.channels.info("Clipboard: rejected malformed remote format list")
            return
        }

        sendPacket(ClipboardWire.makePDU(type: .formatListResponse, flags: ClipboardWire.responseOK))
        RDPLog.channels.debug("Clipboard: received \(formats.ids.count) remote formats")

        if inboundReceiver != nil, negotiatedLocking {
            deferredRemoteFormats = formats
            RDPLog.channels.debug("Clipboard: deferred remote clipboard change until active paste completes")
            return
        }
        activateRemoteFormats(formats)
    }

    private func activateRemoteFormats(_ formats: ClipboardWire.Formats) {
        remoteClipboardGeneration = UUID()
        cancelInboundTransfer(reason: "remote clipboard changed")

        let nextRequest: RemoteFormatRequest?
        if negotiatedFileClip,
           let fileFormat = formats.id(named: ClipboardWire.Format.fileGroupDescriptorName) {
            if negotiatedLocking {
                let clipDataID = nextClipDataID
                nextClipDataID &+= 1
                inboundClipDataID = clipDataID
                sendPacket(ClipboardWire.makeClipDataPDU(type: .lockClipData, id: clipDataID))
            }
            nextRequest = .init(
                formatID: fileFormat,
                kind: .fileList,
                generation: remoteClipboardGeneration
            )
        } else if formats.ids.contains(ClipboardWire.Format.dibV5) {
            nextRequest = .init(
                formatID: ClipboardWire.Format.dibV5,
                kind: .image,
                generation: remoteClipboardGeneration
            )
        } else if formats.ids.contains(ClipboardWire.Format.unicodeText) {
            nextRequest = .init(
                formatID: ClipboardWire.Format.unicodeText,
                kind: .unicodeText,
                generation: remoteClipboardGeneration
            )
        } else if let html = formats.id(named: ClipboardWire.Format.htmlName) {
            nextRequest = .init(formatID: html, kind: .html, generation: remoteClipboardGeneration)
        } else {
            nextRequest = nil
        }
        replaceRemoteFormatRequest(with: nextRequest)
    }

    private func activateDeferredRemoteFormats() {
        guard inboundReceiver == nil, let formats = deferredRemoteFormats else { return }
        deferredRemoteFormats = nil
        activateRemoteFormats(formats)
    }

    private func handleFormatListResponse(flags: UInt16) {
        guard awaitingFormatListResponse else { return }
        awaitingFormatListResponse = false
        announcedFormatsAccepted = flags & ClipboardWire.responseOK != 0
            && flags & ClipboardWire.responseFail == 0
        if !announcedFormatsAccepted {
            RDPLog.channels.info("Clipboard: client rejected local format list")
        }
        if localFormatsDirty {
            sendLocalFormatList()
        }
    }

    private func replaceRemoteFormatRequest(with request: RemoteFormatRequest?) {
        guard pendingFormatRequest == nil else {
            queuedFormatRequest = request
            discardPendingFormatResponse = true
            scheduleRequestTimeout()
            return
        }
        guard let request else { return }
        sendRemoteFormatRequest(request)
    }

    private func sendRemoteFormatRequest(_ request: RemoteFormatRequest) {
        pendingFormatRequest = request
        sendPacket(ClipboardWire.makeFormatDataRequest(request.formatID))
        scheduleRequestTimeout()
    }

    private func sendQueuedFormatRequest() {
        guard let request = queuedFormatRequest else { return }
        queuedFormatRequest = nil
        sendRemoteFormatRequest(request)
    }

    private func acceptLocalClipboard(_ snapshot: ClipboardLocalSnapshot) {
        guard snapshot.changeCount != observedPasteboardChangeCount else { return }
        observedPasteboardChangeCount = snapshot.changeCount
        let replacesExistingClipboard = hasCapturedLocalClipboard
        hasCapturedLocalClipboard = true

        if replacesExistingClipboard {
            remoteClipboardGeneration = UUID()
            deferredRemoteFormats = nil
            if inboundReceiver == nil || !negotiatedLocking {
                cancelInboundTransfer(reason: "local clipboard changed")
                pendingFormatRequest = nil
                queuedFormatRequest = nil
                discardPendingFormatResponse = false
                requestEpoch &+= 1
            } else {
                RDPLog.channels.debug("Clipboard: retained active remote paste after local clipboard change")
            }
        }
        localSnapshot = snapshot
        localFiles = nil

        if !snapshot.fileURLs.isEmpty {
            do {
                localFiles = try ClipboardLocalFileSnapshot.capture(urls: snapshot.fileURLs)
                RDPLog.channels.info("Clipboard: captured \(localFiles?.files.count ?? 0) local file entries")
            } catch {
                RDPLog.channels.info("Clipboard: local file snapshot rejected: \(error.localizedDescription)")
            }
        }

        localFormatsDirty = true
        sendLatestLocalFormatListIfPossible()
    }

    private func sendLatestLocalFormatListIfPossible() {
        guard remoteCapabilities != nil, hasCapturedLocalClipboard else { return }
        guard !awaitingFormatListResponse else {
            localFormatsDirty = true
            return
        }
        sendLocalFormatList()
    }

    private func sendLocalFormatList() {
        localFormatsDirty = false
        announcedSnapshot = localSnapshot
        announcedFiles = localFiles
        announcedFormatsAccepted = false

        var formats: [ClipboardWire.AdvertisedFormat] = []
        if let files = announcedFiles, !files.files.isEmpty, negotiatedFileClip {
            formats = [
                .init(
                    id: ClipboardWire.Format.fileGroupDescriptor,
                    name: ClipboardWire.Format.fileGroupDescriptorName
                ),
                .init(id: ClipboardWire.Format.fileContents, name: ClipboardWire.Format.fileContentsName),
            ]
        } else {
            if announcedSnapshot.html != nil {
                formats.append(.init(id: ClipboardWire.Format.html, name: ClipboardWire.Format.htmlName))
            }
            if announcedSnapshot.text != nil {
                formats.append(.init(id: ClipboardWire.Format.unicodeText, name: nil))
            }
            if announcedSnapshot.imageTIFF != nil {
                formats.append(.init(id: ClipboardWire.Format.dibV5, name: nil))
            }
        }

        sendPacket(ClipboardWire.makeFormatListPDU(formats, longNames: negotiatedLongNames))
        awaitingFormatListResponse = true
        RDPLog.channels.debug("Clipboard: announced \(formats.count) local formats")
    }

    // MARK: - Format data

    private func handleFormatDataRequest(_ body: [UInt8]) {
        guard body.count == 4, announcedFormatsAccepted else {
            sendPacket(ClipboardWire.makeFormatDataResponse(body: nil, success: false))
            return
        }
        let formatID = ClipboardWire.readU32(body, 0)

        switch formatID {
        case ClipboardWire.Format.unicodeText:
            guard let text = announcedSnapshot.text else {
                sendPacket(ClipboardWire.makeFormatDataResponse(body: nil, success: false))
                return
            }
            sendPacket(
                ClipboardWire.makeFormatDataResponse(
                    body: ClipboardWire.encodeUnicodeText(text),
                    success: true
                )
            )

        case ClipboardWire.Format.html:
            guard let html = announcedSnapshot.html else {
                sendPacket(ClipboardWire.makeFormatDataResponse(body: nil, success: false))
                return
            }
            sendPacket(ClipboardWire.makeFormatDataResponse(body: ClipboardWire.encodeHTML(html), success: true))

        case ClipboardWire.Format.dibV5:
            guard let tiff = announcedSnapshot.imageTIFF,
                  let dib = ClipboardImageCodec.encodeDIBV5(tiff: tiff) else {
                sendPacket(ClipboardWire.makeFormatDataResponse(body: nil, success: false))
                return
            }
            sendPacket(ClipboardWire.makeFormatDataResponse(body: dib, success: true))

        case ClipboardWire.Format.fileGroupDescriptor:
            guard negotiatedFileClip, let files = announcedFiles, !files.files.isEmpty else {
                sendPacket(ClipboardWire.makeFormatDataResponse(body: nil, success: false))
                return
            }
            sendPacket(
                ClipboardWire.makeFormatDataResponse(
                    body: ClipboardWire.packFileList(files.descriptors),
                    success: true
                )
            )

        default:
            sendPacket(ClipboardWire.makeFormatDataResponse(body: nil, success: false))
        }
    }

    private func handleFormatDataResponse(flags: UInt16, body: [UInt8]) {
        guard let request = pendingFormatRequest else {
            RDPLog.channels.debug("Clipboard: ignored unsolicited format data response")
            return
        }
        pendingFormatRequest = nil
        requestEpoch &+= 1
        if discardPendingFormatResponse {
            discardPendingFormatResponse = false
            RDPLog.channels.debug("Clipboard: discarded stale format data response")
            sendQueuedFormatRequest()
            return
        }
        guard flags & ClipboardWire.responseOK != 0, flags & ClipboardWire.responseFail == 0 else {
            if case .fileList = request.kind {
                failInboundTransfer(.remoteFailure)
            }
            return
        }

        switch request.kind {
        case .unicodeText:
            guard let text = ClipboardWire.decodeUnicodeText(body) else { return }
            publishRemoteContent(.text(text), generation: request.generation)

        case .html:
            guard let html = ClipboardWire.decodeHTML(body) else { return }
            publishRemoteContent(.html(html), generation: request.generation)

        case .image:
            guard let image = ClipboardImageCodec.decodeDIBV5(body) else {
                RDPLog.channels.error("Clipboard: rejected DIBV5 image (\(body.count)B)")
                return
            }
            publishRemoteContent(.image(image), generation: request.generation)

        case .fileList:
            guard let descriptors = ClipboardWire.parseFileList(body), !descriptors.isEmpty else {
                failInboundTransfer(.invalidResponse)
                return
            }
            do {
                let promise = try ClipboardRemoteFilePromise(descriptors: descriptors) { [weak self] promise in
                    guard let self else {
                        promise.fail()
                        return
                    }
                    self.stateQueue.async { [weak self, weak promise] in
                        guard let self, let promise else { return }
                        self.startInboundTransfer(for: promise)
                    }
                }
                inboundPromise = promise
                publishRemoteContent(.files(promise), generation: request.generation)
                RDPLog.channels.info(
                    "Clipboard: published \(promise.topLevelNames.count) lazy remote file items"
                )
            } catch let error as ClipboardFileTransferError {
                failInboundTransfer(error)
            } catch {
                failInboundTransfer(.ioFailure(error.localizedDescription))
            }
        }
    }

    // MARK: - Inbound files (Windows -> Mac)

    private func startInboundTransfer(for promise: ClipboardRemoteFilePromise) {
        guard inboundPromise === promise, inboundReceiver == nil else {
            promise.fail()
            return
        }
        var directory: URL?
        do {
            let transferDirectory = try stagingStore.makeTransferDirectory()
            directory = transferDirectory
            let receiver = ClipboardFileReceiver(
                manifest: promise.manifest,
                destinationRoot: transferDirectory,
                streamIDs: inboundStreamIDs
            )
            inboundDirectory = transferDirectory
            inboundReceiver = receiver
            processReceiverEvent(receiver.start())
        } catch let error as ClipboardFileTransferError {
            if let directory {
                stagingStore.discard(directory)
            }
            failInboundTransfer(error)
        } catch {
            if let directory {
                stagingStore.discard(directory)
            }
            failInboundTransfer(.ioFailure(error.localizedDescription))
        }
    }

    private func handleFileContentsResponse(flags: UInt16, body: [UInt8]) {
        guard body.count >= 4 else {
            if inboundReceiver != nil {
                failInboundTransfer(.invalidResponse)
            }
            return
        }
        guard let receiver = inboundReceiver else {
            RDPLog.channels.debug("Clipboard: ignored file response with no active request")
            return
        }
        let streamID = ClipboardWire.readU32(body, 0)
        let success = flags & ClipboardWire.responseOK != 0 && flags & ClipboardWire.responseFail == 0
        let event = receiver.acceptResponse(
            streamID: streamID,
            success: success,
            data: Array(body.dropFirst(4))
        )
        if case .ignored = event {
            processReceiverEvent(event)
            return
        }
        requestEpoch &+= 1
        processReceiverEvent(event)
    }

    private func processReceiverEvent(_ event: ClipboardFileReceiver.Event) {
        switch event {
        case .request(let request):
            let flags: UInt32
            let offset: UInt64
            let requestedBytes: UInt32
            switch request.kind {
            case .size:
                flags = ClipboardWire.FileContentsFlag.size
                offset = 0
                requestedBytes = 8
            case .range(let requestOffset, let length):
                flags = ClipboardWire.FileContentsFlag.range
                offset = requestOffset
                requestedBytes = length
            }
            sendPacket(
                ClipboardWire.makeFileContentsRequest(
                    streamID: request.streamID,
                    listIndex: request.listIndex,
                    flags: flags,
                    offset: offset,
                    requestedBytes: requestedBytes,
                    clipDataID: inboundClipDataID
                )
            )
            scheduleRequestTimeout()

        case .completed(let urls):
            inboundReceiver = nil
            inboundDirectory = nil
            unlockInboundClipboard()
            inboundPromise?.complete(with: urls)
            RDPLog.channels.info("Clipboard: materialized \(urls.count) top-level file items")
            activateDeferredRemoteFormats()

        case .failed(let error):
            failInboundTransfer(error)

        case .ignored:
            RDPLog.channels.debug("Clipboard: ignored stale file response")
        }
    }

    private func failInboundTransfer(_ error: ClipboardFileTransferError) {
        RDPLog.channels.info("Clipboard: file receive failed: \(error.localizedDescription)")
        cancelInboundTransfer(reason: error.localizedDescription)
        activateDeferredRemoteFormats()
    }

    private func cancelInboundTransfer(reason: String) {
        requestEpoch &+= 1
        inboundReceiver?.cancel()
        inboundReceiver = nil
        inboundPromise?.fail()
        inboundPromise = nil
        if let directory = inboundDirectory {
            stagingStore.discard(directory)
            inboundDirectory = nil
        }
        unlockInboundClipboard()
        RDPLog.channels.debug("Clipboard: cancelled inbound transfer (\(reason))")
    }

    private func unlockInboundClipboard() {
        guard let clipDataID = inboundClipDataID else { return }
        sendPacket(ClipboardWire.makeClipDataPDU(type: .unlockClipData, id: clipDataID))
        inboundClipDataID = nil
    }

    // MARK: - Outbound files (Mac -> Windows)

    private func handlePeerLock(_ body: [UInt8]) {
        guard negotiatedLocking, body.count == 4, let announcedFiles else { return }
        let id = ClipboardWire.readU32(body, 0)
        if lockedFileSnapshots.count >= 32, lockedFileSnapshots[id] == nil {
            RDPLog.channels.info("Clipboard: refused excess peer file lock")
            return
        }
        lockedFileSnapshots[id] = announcedFiles
        RDPLog.channels.debug("Clipboard: retained file snapshot for lock \(id)")
    }

    private func handlePeerUnlock(_ body: [UInt8]) {
        guard body.count == 4 else { return }
        lockedFileSnapshots.removeValue(forKey: ClipboardWire.readU32(body, 0))
    }

    private func handleFileContentsRequest(_ body: [UInt8]) {
        guard let request = ClipboardWire.parseFileContentsRequest(body) else {
            if body.count >= 4 {
                sendFileFailure(streamID: ClipboardWire.readU32(body, 0))
            }
            return
        }
        guard negotiatedFileClip,
              request.flags == ClipboardWire.FileContentsFlag.size
                || request.flags == ClipboardWire.FileContentsFlag.range else {
            sendFileFailure(streamID: request.streamID)
            return
        }

        let snapshot: ClipboardLocalFileSnapshot?
        if let clipDataID = request.clipDataID {
            snapshot = lockedFileSnapshots[clipDataID]
        } else {
            snapshot = announcedFormatsAccepted ? announcedFiles : nil
        }
        guard let snapshot, Int(request.listIndex) < snapshot.files.count else {
            sendFileFailure(streamID: request.streamID)
            return
        }
        let file = snapshot.files[Int(request.listIndex)]

        if request.flags == ClipboardWire.FileContentsFlag.size {
            guard request.offset == 0, request.requestedBytes == 8 else {
                sendFileFailure(streamID: request.streamID)
                return
            }
            let size = file.descriptor.isDirectory ? 0 : file.descriptor.size ?? 0
            var data: [UInt8] = []
            data.appendU32(UInt32(size & 0xFFFF_FFFF))
            data.appendU32(UInt32(size >> 32))
            sendPacket(
                ClipboardWire.makeFileContentsResponse(
                    streamID: request.streamID,
                    data: data,
                    success: true
                )
            )
            return
        }

        guard !file.descriptor.isDirectory,
              request.requestedBytes > 0,
              request.requestedBytes <= UInt32(ClipboardWire.maximumPDUSize - 4),
              let size = file.descriptor.size else {
            sendFileFailure(streamID: request.streamID)
            return
        }
        guard request.offset <= size else {
            sendFileFailure(streamID: request.streamID)
            return
        }
        let count = Int(min(UInt64(request.requestedBytes), size - request.offset))
        let data: [UInt8]?
        if count == 0 {
            data = []
        } else {
            data = readFile(file.sourceURL, offset: request.offset, count: count)
        }
        guard let data else {
            sendFileFailure(streamID: request.streamID)
            return
        }
        sendPacket(
            ClipboardWire.makeFileContentsResponse(
                streamID: request.streamID,
                data: data,
                success: true
            )
        )
    }

    private func readFile(_ url: URL, offset: UInt64, count: Int) -> [UInt8]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            var result = Data()
            result.reserveCapacity(count)
            while result.count < count {
                let chunk = try handle.read(upToCount: count - result.count) ?? Data()
                guard !chunk.isEmpty else { return nil }
                result.append(chunk)
            }
            return Array(result)
        } catch {
            return nil
        }
    }

    private func sendFileFailure(streamID: UInt32) {
        sendPacket(
            ClipboardWire.makeFileContentsResponse(
                streamID: streamID,
                data: nil,
                success: false
            )
        )
    }

    private func resetSessionState() {
        channelID = 0
        handshakeSent = false
        remoteCapabilities = nil
        negotiatedLongNames = false
        negotiatedFileClip = false
        negotiatedLocking = false
        remoteClipboardGeneration = UUID()

        localSnapshot = .empty
        localFiles = nil
        hasCapturedLocalClipboard = false
        announcedSnapshot = .empty
        announcedFiles = nil
        announcedFormatsAccepted = false
        awaitingFormatListResponse = false
        localFormatsDirty = false
        lockedFileSnapshots.removeAll()

        pendingFormatRequest = nil
        queuedFormatRequest = nil
        discardPendingFormatResponse = false
        deferredRemoteFormats = nil
        inboundPromise?.fail()
        inboundPromise = nil
        inboundReceiver = nil
        inboundDirectory = nil
        inboundClipDataID = nil
        observedPasteboardChangeCount = -1
        requestEpoch &+= 1
    }

    // MARK: - Pasteboard and timeout coordination

    private func startPasteboardMonitor(for generation: UUID) {
        guard monitorSystemPasteboard else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.monitorTimer?.cancel()
            self.monitoredPasteboardChangeCount = -1
            self.captureSystemPasteboard(for: generation)
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak self] in
                self?.captureSystemPasteboard(for: generation)
            }
            timer.resume()
            self.monitorTimer = timer
        }
    }

    private func stopPasteboardMonitor() {
        DispatchQueue.main.async { [weak self] in
            self?.monitorTimer?.cancel()
            self?.monitorTimer = nil
        }
    }

    private func captureSystemPasteboard(for generation: UUID) {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != monitoredPasteboardChangeCount else { return }
        monitoredPasteboardChangeCount = changeCount
        let snapshot = ClipboardPasteboardBridge.capture(pasteboard)
        stateQueue.async { [weak self] in
            guard let self, self.sessionGeneration == generation, self.handshakeSent else { return }
            self.acceptLocalClipboard(snapshot)
        }
    }

    private func publishRemoteContent(_ content: ClipboardRemoteContent, generation: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let isCurrent = self.stateQueue.sync {
                self.handshakeSent && self.remoteClipboardGeneration == generation
            }
            guard isCurrent else {
                RDPLog.channels.debug("Clipboard: skipped stale pasteboard publication")
                return
            }
            let changeCount = self.remoteContentPublisher(content)
            self.monitoredPasteboardChangeCount = changeCount
            self.stateQueue.async { [weak self] in
                guard let self, self.remoteClipboardGeneration == generation else { return }
                self.observedPasteboardChangeCount = changeCount
            }
        }
    }

    private func scheduleRequestTimeout() {
        requestEpoch &+= 1
        let epoch = requestEpoch
        stateQueue.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
            guard let self, self.requestEpoch == epoch else { return }
            if let request = self.pendingFormatRequest {
                self.pendingFormatRequest = nil
                if self.discardPendingFormatResponse {
                    self.discardPendingFormatResponse = false
                    self.sendQueuedFormatRequest()
                } else if case .fileList = request.kind {
                    self.failInboundTransfer(.remoteFailure)
                }
            } else if self.inboundReceiver != nil {
                self.failInboundTransfer(.remoteFailure)
            }
        }
    }

    private func sendPacket(_ packet: [UInt8]) {
        send?(packet)
    }

}
