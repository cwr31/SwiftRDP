import Foundation

enum ClipboardTransferLimits {
    static let maximumItemCount = 4_096
    static let maximumPathUTF16Units = 259
    // Windows RDP clipboard copy supports files smaller than 2 GiB (KB2258090).
    static let maximumFileSize = UInt64(Int32.max)
    static let maximumTotalSize: UInt64 = 128 * 1024 * 1024 * 1024
    static let chunkSize: UInt32 = 1024 * 1024
    static let requestTimeout: TimeInterval = 30
    static let completedFileLifetime: TimeInterval = 24 * 60 * 60
}

enum ClipboardFileTransferError: LocalizedError, Equatable {
    case tooManyItems
    case unsupportedItem(String)
    case invalidPath(String)
    case duplicatePath(String)
    case fileTooLarge(String)
    case transferTooLarge
    case invalidResponse
    case remoteFailure
    case ioFailure(String)

    var errorDescription: String? {
        switch self {
        case .tooManyItems:
            return "clipboard contains too many files"
        case .unsupportedItem(let path):
            return "unsupported clipboard item: \(path)"
        case .invalidPath(let path):
            return "invalid clipboard path: \(path)"
        case .duplicatePath(let path):
            return "duplicate clipboard path: \(path)"
        case .fileTooLarge(let path):
            return "clipboard file exceeds the transfer limit: \(path)"
        case .transferTooLarge:
            return "clipboard transfer exceeds the total size limit"
        case .invalidResponse:
            return "invalid clipboard file response"
        case .remoteFailure:
            return "remote clipboard file request failed"
        case .ioFailure(let message):
            return "clipboard file I/O failed: \(message)"
        }
    }
}

struct ClipboardLocalFile: Equatable {
    let descriptor: ClipboardWire.FileDescriptor
    let sourceURL: URL
}

struct ClipboardLocalFileSnapshot: Equatable {
    let files: [ClipboardLocalFile]

    var descriptors: [ClipboardWire.FileDescriptor] {
        files.map(\.descriptor)
    }

    static func capture(urls: [URL], fileManager: FileManager = .default) throws -> Self {
        var files: [ClipboardLocalFile] = []
        var seenPaths = Set<String>()
        var totalSize: UInt64 = 0

        for root in urls {
            let rootName = root.lastPathComponent
            try append(
                url: root,
                relativePath: rootName,
                fileManager: fileManager,
                files: &files,
                seenPaths: &seenPaths,
                totalSize: &totalSize
            )
        }
        guard !files.isEmpty else {
            throw ClipboardFileTransferError.unsupportedItem("empty file list")
        }
        return Self(files: files)
    }

    private static func append(
        url: URL,
        relativePath: String,
        fileManager: FileManager,
        files: inout [ClipboardLocalFile],
        seenPaths: inout Set<String>,
        totalSize: inout UInt64
    ) throws {
        guard files.count < ClipboardTransferLimits.maximumItemCount else {
            throw ClipboardFileTransferError.tooManyItems
        }
        let path = try ClipboardPath.validate(relativePath)
        let collisionKey = path.precomposedStringWithCanonicalMapping.lowercased()
        guard seenPaths.insert(collisionKey).inserted else {
            throw ClipboardFileTransferError.duplicatePath(path)
        }

        var currentURL = url
        currentURL.removeAllCachedResourceValues()
        let values: URLResourceValues
        do {
            values = try currentURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ])
        } catch {
            throw ClipboardFileTransferError.ioFailure(error.localizedDescription)
        }
        guard values.isSymbolicLink != true else {
            throw ClipboardFileTransferError.unsupportedItem(path)
        }

        if values.isDirectory == true {
            files.append(
                ClipboardLocalFile(
                    descriptor: .init(
                        relativePath: path,
                        isDirectory: true,
                        size: nil,
                        modifiedAt: values.contentModificationDate
                    ),
                    sourceURL: currentURL
                )
            )
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: currentURL,
                    includingPropertiesForKeys: nil,
                    options: []
                ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } catch {
                throw ClipboardFileTransferError.ioFailure(error.localizedDescription)
            }
            for child in children {
                try append(
                    url: child,
                    relativePath: path + "\\" + child.lastPathComponent,
                    fileManager: fileManager,
                    files: &files,
                    seenPaths: &seenPaths,
                    totalSize: &totalSize
                )
            }
            return
        }

        guard values.isRegularFile == true else {
            throw ClipboardFileTransferError.unsupportedItem(path)
        }
        let size = UInt64(values.fileSize ?? 0)
        guard size <= ClipboardTransferLimits.maximumFileSize else {
            throw ClipboardFileTransferError.fileTooLarge(path)
        }
        let (newTotal, overflow) = totalSize.addingReportingOverflow(size)
        guard !overflow, newTotal <= ClipboardTransferLimits.maximumTotalSize else {
            throw ClipboardFileTransferError.transferTooLarge
        }
        totalSize = newTotal
        files.append(
            ClipboardLocalFile(
                descriptor: .init(
                    relativePath: path,
                    isDirectory: false,
                    size: size,
                    modifiedAt: values.contentModificationDate
                ),
                sourceURL: currentURL
            )
        )
    }
}

enum ClipboardPath {
    static func validate(_ rawPath: String) throws -> String {
        guard !rawPath.isEmpty,
              rawPath.utf16.count <= ClipboardTransferLimits.maximumPathUTF16Units,
              !rawPath.hasPrefix("/"),
              !rawPath.hasPrefix("\\"),
              !rawPath.contains("\0") else {
            throw ClipboardFileTransferError.invalidPath(rawPath)
        }
        let normalized = rawPath.replacingOccurrences(of: "/", with: "\\")
        let components = normalized.split(separator: "\\", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.count <= 64,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") }) else {
            throw ClipboardFileTransferError.invalidPath(rawPath)
        }
        return components.joined(separator: "\\")
    }

    static func targetURL(for relativePath: String, under root: URL) throws -> URL {
        let path = try validate(relativePath)
        return path.split(separator: "\\").reduce(root) { partial, component in
            partial.appendingPathComponent(String(component), isDirectory: false)
        }
    }

}

struct ClipboardFileManifest {
    let descriptors: [ClipboardWire.FileDescriptor]
    let topLevelNames: [String]

    init(descriptors: [ClipboardWire.FileDescriptor]) throws {
        guard !descriptors.isEmpty,
              descriptors.count <= ClipboardTransferLimits.maximumItemCount else {
            throw ClipboardFileTransferError.tooManyItems
        }

        var itemKinds: [String: Bool] = [:]
        var topLevelNames: [String] = []
        var seenTopLevels = Set<String>()
        var declaredSize: UInt64 = 0

        for descriptor in descriptors {
            let path = try ClipboardPath.validate(descriptor.relativePath)
            let collisionKey = Self.key(path)
            guard itemKinds.updateValue(descriptor.isDirectory, forKey: collisionKey) == nil else {
                throw ClipboardFileTransferError.duplicatePath(path)
            }

            if !descriptor.isDirectory, let size = descriptor.size {
                guard size <= ClipboardTransferLimits.maximumFileSize else {
                    throw ClipboardFileTransferError.fileTooLarge(path)
                }
                let (newSize, overflow) = declaredSize.addingReportingOverflow(size)
                guard !overflow, newSize <= ClipboardTransferLimits.maximumTotalSize else {
                    throw ClipboardFileTransferError.transferTooLarge
                }
                declaredSize = newSize
            }

            if let first = path.split(separator: "\\").first {
                let name = String(first)
                if seenTopLevels.insert(Self.key(name)).inserted {
                    topLevelNames.append(name)
                }
            }
        }

        for descriptor in descriptors {
            let components = try ClipboardPath.validate(descriptor.relativePath).split(separator: "\\")
            guard components.count > 1 else { continue }
            for end in 1..<components.count {
                let parent = components[..<end].joined(separator: "\\")
                if itemKinds[Self.key(parent)] == false {
                    throw ClipboardFileTransferError.invalidPath(descriptor.relativePath)
                }
            }
        }

        guard !topLevelNames.isEmpty else {
            throw ClipboardFileTransferError.invalidResponse
        }
        self.descriptors = descriptors
        self.topLevelNames = topLevelNames
    }

    func topLevelURLs(under root: URL) -> [URL] {
        topLevelNames.map { root.appendingPathComponent($0) }
    }

    static func key(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }
}

final class ClipboardRemoteFilePromise: @unchecked Sendable {
    let manifest: ClipboardFileManifest

    var topLevelNames: [String] {
        manifest.topLevelNames
    }

    private enum State {
        case idle
        case loading
        case completed([String: URL])
        case failed
    }

    private let condition = NSCondition()
    private let startHandler: (ClipboardRemoteFilePromise) -> Void
    private var state: State = .idle

    init(
        descriptors: [ClipboardWire.FileDescriptor],
        startHandler: @escaping (ClipboardRemoteFilePromise) -> Void
    ) throws {
        self.manifest = try ClipboardFileManifest(descriptors: descriptors)
        self.startHandler = startHandler
    }

    func resolveTopLevel(named name: String) -> URL? {
        var shouldStart = false
        condition.lock()
        if case .idle = state {
            state = .loading
            shouldStart = true
        }
        condition.unlock()

        if shouldStart {
            startHandler(self)
        }

        condition.lock()
        defer { condition.unlock() }
        while case .loading = state {
            condition.wait()
        }
        guard case .completed(let urls) = state else { return nil }
        return urls[ClipboardFileManifest.key(name)]
    }

    func complete(with urls: [URL]) {
        guard urls.count == manifest.topLevelNames.count else {
            fail()
            return
        }
        let resolved = Dictionary(
            uniqueKeysWithValues: zip(manifest.topLevelNames, urls).map {
                (ClipboardFileManifest.key($0.0), $0.1)
            }
        )

        condition.lock()
        if case .loading = state {
            state = .completed(resolved)
            condition.broadcast()
        }
        condition.unlock()
    }

    func fail() {
        condition.lock()
        switch state {
        case .idle, .loading:
            state = .failed
            condition.broadcast()
        case .completed, .failed:
            break
        }
        condition.unlock()
    }
}

final class ClipboardStagingStore {
    let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftRDP/Clipboard", isDirectory: true)
        try? fileManager.createDirectory(
            at: self.rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.rootURL.path)
        removeExpiredTransfers()
    }

    func makeTransferDirectory() throws -> URL {
        removeExpiredTransfers()
        let url = rootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    func discard(_ url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == rootURL.standardizedFileURL else { return }
        try? fileManager.removeItem(at: url)
    }

    private func removeExpiredTransfers() {
        guard let children = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-ClipboardTransferLimits.completedFileLifetime)
        for child in children {
            let modified = try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if modified.map({ $0 < cutoff }) ?? true {
                try? fileManager.removeItem(at: child)
            }
        }
    }
}

final class ClipboardStreamIDAllocator {
    private var nextID: UInt32

    init(initialID: UInt32 = 1) {
        self.nextID = initialID == 0 ? 1 : initialID
    }

    func next() -> UInt32 {
        let id = nextID
        nextID &+= 1
        if nextID == 0 {
            nextID = 1
        }
        return id
    }
}

final class ClipboardFileReceiver {
    struct Request: Equatable {
        enum Kind: Equatable {
            case size
            case range(offset: UInt64, length: UInt32)
        }

        let streamID: UInt32
        let listIndex: UInt32
        let kind: Kind
    }

    enum Event: Equatable {
        case request(Request)
        case completed([URL])
        case failed(ClipboardFileTransferError)
        case ignored
    }

    let destinationRoot: URL

    private let manifest: ClipboardFileManifest
    private let fileManager: FileManager
    private let streamIDs: ClipboardStreamIDAllocator
    private var nextIndex = 0
    private var outstanding: Request?
    private var outputHandle: FileHandle?
    private var expectedSize: UInt64 = 0
    private var receivedSize: UInt64 = 0
    private var totalSize: UInt64 = 0
    private var finished = false

    init(
        manifest: ClipboardFileManifest,
        destinationRoot: URL,
        streamIDs: ClipboardStreamIDAllocator,
        fileManager: FileManager = .default
    ) {
        self.manifest = manifest
        self.destinationRoot = destinationRoot
        self.streamIDs = streamIDs
        self.fileManager = fileManager
    }

    func start() -> Event {
        advanceToNextFile()
    }

    func acceptResponse(streamID: UInt32, success: Bool, data: [UInt8]) -> Event {
        guard !finished, let request = outstanding, request.streamID == streamID else { return .ignored }
        outstanding = nil
        guard success else { return fail(.remoteFailure) }

        switch request.kind {
        case .size:
            guard data.count == 8 else { return fail(.invalidResponse) }
            let size = ClipboardWire.readU64(data, 0)
            guard size <= ClipboardTransferLimits.maximumFileSize else {
                return fail(.fileTooLarge(manifest.descriptors[Int(request.listIndex)].relativePath))
            }
            let (newTotal, overflow) = totalSize.addingReportingOverflow(size)
            guard !overflow, newTotal <= ClipboardTransferLimits.maximumTotalSize else {
                return fail(.transferTooLarge)
            }
            totalSize = newTotal
            expectedSize = size
            receivedSize = 0
            guard prepareOutputFile(at: Int(request.listIndex)) else {
                return fail(.ioFailure(manifest.descriptors[Int(request.listIndex)].relativePath))
            }
            if size == 0 {
                finishCurrentFile()
                return advanceToNextFile()
            }
            return makeRangeRequest(index: request.listIndex)

        case .range(let offset, let length):
            guard offset == receivedSize,
                  !data.isEmpty,
                  data.count <= Int(length),
                  UInt64(data.count) <= expectedSize - receivedSize,
                  let outputHandle else {
                return fail(.invalidResponse)
            }
            do {
                try outputHandle.write(contentsOf: Data(data))
            } catch {
                return fail(.ioFailure(error.localizedDescription))
            }
            receivedSize += UInt64(data.count)
            if receivedSize == expectedSize {
                finishCurrentFile()
                return advanceToNextFile()
            }
            return makeRangeRequest(index: request.listIndex)
        }
    }

    func cancel() {
        finished = true
        outstanding = nil
        try? outputHandle?.close()
        outputHandle = nil
    }

    private func advanceToNextFile() -> Event {
        while nextIndex < manifest.descriptors.count {
            let index = nextIndex
            nextIndex += 1
            let descriptor = manifest.descriptors[index]
            guard let target = try? ClipboardPath.targetURL(for: descriptor.relativePath, under: destinationRoot) else {
                return fail(.invalidPath(descriptor.relativePath))
            }
            if descriptor.isDirectory {
                do {
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                    applyModificationDate(descriptor.modifiedAt, to: target)
                } catch {
                    return fail(.ioFailure(error.localizedDescription))
                }
                continue
            }
            return makeSizeRequest(index: UInt32(index))
        }

        finished = true
        return .completed(manifest.topLevelURLs(under: destinationRoot))
    }

    private func makeSizeRequest(index: UInt32) -> Event {
        let request = Request(streamID: allocateStreamID(), listIndex: index, kind: .size)
        outstanding = request
        return .request(request)
    }

    private func makeRangeRequest(index: UInt32) -> Event {
        let remaining = expectedSize - receivedSize
        let length = UInt32(min(UInt64(ClipboardTransferLimits.chunkSize), remaining))
        let request = Request(
            streamID: allocateStreamID(),
            listIndex: index,
            kind: .range(offset: receivedSize, length: length)
        )
        outstanding = request
        return .request(request)
    }

    private func allocateStreamID() -> UInt32 {
        streamIDs.next()
    }

    private func prepareOutputFile(at index: Int) -> Bool {
        let descriptor = manifest.descriptors[index]
        guard let target = try? ClipboardPath.targetURL(for: descriptor.relativePath, under: destinationRoot) else {
            return false
        }
        do {
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard fileManager.createFile(atPath: target.path, contents: nil) else { return false }
            outputHandle = try FileHandle(forWritingTo: target)
            return true
        } catch {
            return false
        }
    }

    private func finishCurrentFile() {
        try? outputHandle?.close()
        outputHandle = nil
        let descriptor = manifest.descriptors[nextIndex - 1]
        if let target = try? ClipboardPath.targetURL(for: descriptor.relativePath, under: destinationRoot) {
            applyModificationDate(descriptor.modifiedAt, to: target)
        }
    }

    private func applyModificationDate(_ date: Date?, to url: URL) {
        guard let date else { return }
        try? fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func fail(_ error: ClipboardFileTransferError) -> Event {
        cancel()
        return .failed(error)
    }
}
