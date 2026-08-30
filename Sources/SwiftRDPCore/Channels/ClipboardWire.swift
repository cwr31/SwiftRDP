import Foundation

enum ClipboardWire {
    static let maximumPDUSize = 64 * 1024 * 1024
    static let fileDescriptorSize = 592

    enum MessageType: UInt16 {
        case monitorReady = 0x0001
        case formatList = 0x0002
        case formatListResponse = 0x0003
        case formatDataRequest = 0x0004
        case formatDataResponse = 0x0005
        case temporaryDirectory = 0x0006
        case capabilities = 0x0007
        case fileContentsRequest = 0x0008
        case fileContentsResponse = 0x0009
        case lockClipData = 0x000A
        case unlockClipData = 0x000B
    }

    enum Format {
        static let unicodeText: UInt32 = 13
        static let dibV5: UInt32 = 17

        // Registered clipboard format IDs are scoped to the endpoint that advertises them.
        static let fileGroupDescriptor: UInt32 = 0xC000
        static let fileContents: UInt32 = 0xC001
        static let html: UInt32 = 0xC002

        static let fileGroupDescriptorName = "FileGroupDescriptorW"
        static let fileContentsName = "FileContents"
        static let htmlName = "HTML Format"
    }

    enum Capability {
        static let useLongFormatNames: UInt32 = 0x0000_0002
        static let streamFileClip: UInt32 = 0x0000_0004
        static let noFilePaths: UInt32 = 0x0000_0008
        static let canLockClipData: UInt32 = 0x0000_0010
    }

    enum FileContentsFlag {
        static let size: UInt32 = 0x0000_0001
        static let range: UInt32 = 0x0000_0002
    }

    static let responseOK: UInt16 = 0x0001
    static let responseFail: UInt16 = 0x0002

    struct PDU {
        let type: MessageType
        let flags: UInt16
        let body: [UInt8]
    }

    struct Capabilities: Equatable {
        let useLongFormatNames: Bool
        let streamFileClip: Bool
        let noFilePaths: Bool
        let canLockClipData: Bool
    }

    struct Formats: Equatable {
        var ids: [UInt32] = []
        var named: [String: UInt32] = [:]

        func id(named name: String) -> UInt32? {
            named[name.lowercased()]
        }
    }

    struct AdvertisedFormat: Equatable {
        let id: UInt32
        let name: String?
    }

    struct FileDescriptor: Equatable {
        let relativePath: String
        let isDirectory: Bool
        let size: UInt64?
        let modifiedAt: Date?
    }

    struct FileContentsRequest: Equatable {
        let streamID: UInt32
        let listIndex: UInt32
        let flags: UInt32
        let offset: UInt64
        let requestedBytes: UInt32
        let clipDataID: UInt32?
    }

    static func parsePDU(_ data: [UInt8]) -> PDU? {
        guard data.count >= 8,
              let type = MessageType(rawValue: readU16(data, 0)) else {
            return nil
        }
        let length = Int(readU32(data, 4))
        guard length <= maximumPDUSize, data.count >= 8 + length else { return nil }
        return PDU(type: type, flags: readU16(data, 2), body: Array(data[8..<(8 + length)]))
    }

    static func makePDU(type: MessageType, flags: UInt16 = 0, body: [UInt8] = []) -> [UInt8] {
        var data: [UInt8] = []
        data.appendU16(type.rawValue)
        data.appendU16(flags)
        data.appendU32(UInt32(body.count))
        data.append(contentsOf: body)
        return data
    }

    static func makeCapabilitiesPDU() -> [UInt8] {
        var set: [UInt8] = []
        set.appendU16(0x0001)
        set.appendU16(12)
        set.appendU32(2)
        set.appendU32(
            Capability.useLongFormatNames
                | Capability.streamFileClip
                | Capability.noFilePaths
                | Capability.canLockClipData
        )

        var body: [UInt8] = []
        body.appendU16(1)
        body.appendU16(0)
        body.append(contentsOf: set)
        return makePDU(type: .capabilities, body: body)
    }

    static func parseCapabilities(_ body: [UInt8]) -> Capabilities? {
        guard body.count >= 4 else { return nil }
        let count = Int(readU16(body, 0))
        var offset = 4
        for _ in 0..<count {
            guard offset + 4 <= body.count else { return nil }
            let type = readU16(body, offset)
            let length = Int(readU16(body, offset + 2))
            guard length >= 4, offset + length <= body.count else { return nil }
            if type == 0x0001, length >= 12 {
                let flags = readU32(body, offset + 8)
                return Capabilities(
                    useLongFormatNames: flags & Capability.useLongFormatNames != 0,
                    streamFileClip: flags & Capability.streamFileClip != 0,
                    noFilePaths: flags & Capability.noFilePaths != 0,
                    canLockClipData: flags & Capability.canLockClipData != 0
                )
            }
            offset += length
        }
        return nil
    }

    static func parseFormatList(_ body: [UInt8], longNames: Bool, asciiShortNames: Bool) -> Formats? {
        var formats = Formats()
        var offset = 0
        while offset < body.count {
            guard offset + 4 <= body.count else { return nil }
            let id = readU32(body, offset)
            offset += 4

            let name: String
            if longNames {
                var units: [UInt16] = []
                var terminated = false
                while offset + 1 < body.count {
                    let unit = readU16(body, offset)
                    offset += 2
                    if unit == 0 {
                        terminated = true
                        break
                    }
                    units.append(unit)
                }
                guard terminated else { return nil }
                name = String(decoding: units, as: UTF16.self)
            } else {
                guard offset + 32 <= body.count else { return nil }
                let bytes = body[offset..<(offset + 32)]
                if asciiShortNames {
                    name = String(bytes: bytes.prefix { $0 != 0 }, encoding: .ascii) ?? ""
                } else {
                    var units: [UInt16] = []
                    for index in stride(from: offset, to: offset + 32, by: 2) {
                        let unit = readU16(body, index)
                        if unit == 0 { break }
                        units.append(unit)
                    }
                    name = String(decoding: units, as: UTF16.self)
                }
                offset += 32
            }

            formats.ids.append(id)
            if !name.isEmpty {
                formats.named[name.lowercased()] = id
            }
        }
        return formats
    }

    static func makeFormatListPDU(_ formats: [AdvertisedFormat], longNames: Bool) -> [UInt8] {
        var body: [UInt8] = []
        for format in formats {
            body.appendU32(format.id)
            if longNames {
                if let name = format.name {
                    body.appendUTF16LE(name)
                }
                body.appendU16(0)
            } else {
                if let name = format.name {
                    body.append(contentsOf: name.utf8.prefix(31))
                }
                while body.count.isMultiple(of: 36) == false {
                    body.append(0)
                }
            }
        }
        return makePDU(type: .formatList, flags: longNames ? 0 : 0x0004, body: body)
    }

    static func makeFormatDataRequest(_ formatID: UInt32) -> [UInt8] {
        makePDU(type: .formatDataRequest, body: bytes(formatID))
    }

    static func makeFormatDataResponse(body: [UInt8]?, success: Bool) -> [UInt8] {
        makePDU(
            type: .formatDataResponse,
            flags: success ? responseOK : responseFail,
            body: body ?? []
        )
    }

    static func makeClipDataPDU(type: MessageType, id: UInt32) -> [UInt8] {
        makePDU(type: type, body: bytes(id))
    }

    static func parseFileContentsRequest(_ body: [UInt8]) -> FileContentsRequest? {
        guard body.count == 24 || body.count == 28 else { return nil }
        return FileContentsRequest(
            streamID: readU32(body, 0),
            listIndex: readU32(body, 4),
            flags: readU32(body, 8),
            offset: readU64(body, 12),
            requestedBytes: readU32(body, 20),
            clipDataID: body.count == 28 ? readU32(body, 24) : nil
        )
    }

    static func makeFileContentsRequest(
        streamID: UInt32,
        listIndex: UInt32,
        flags: UInt32,
        offset: UInt64,
        requestedBytes: UInt32,
        clipDataID: UInt32?
    ) -> [UInt8] {
        var body: [UInt8] = []
        body.appendU32(streamID)
        body.appendU32(listIndex)
        body.appendU32(flags)
        body.appendU64(offset)
        body.appendU32(requestedBytes)
        if let clipDataID {
            body.appendU32(clipDataID)
        }
        return makePDU(type: .fileContentsRequest, body: body)
    }

    static func makeFileContentsResponse(streamID: UInt32, data: [UInt8]?, success: Bool) -> [UInt8] {
        var body: [UInt8] = []
        body.appendU32(streamID)
        if let data, success {
            body.append(contentsOf: data)
        }
        return makePDU(
            type: .fileContentsResponse,
            flags: success ? responseOK : responseFail,
            body: body
        )
    }

    static func packFileList(_ descriptors: [FileDescriptor]) -> [UInt8] {
        var body: [UInt8] = []
        body.appendU32(UInt32(descriptors.count))
        for descriptor in descriptors {
            var data = [UInt8](repeating: 0, count: fileDescriptorSize)
            var flags: UInt32 = 0x0000_0004 | 0x8000_0000 // FD_ATTRIBUTES | FD_UNICODE
            if descriptor.modifiedAt != nil { flags |= 0x0000_0020 } // FD_WRITESTIME
            if descriptor.size != nil { flags |= 0x0000_0040 } // FD_FILESIZE
            writeU32(&data, 0, flags)
            writeU32(&data, 36, descriptor.isDirectory ? 0x10 : 0x80)
            if let modifiedAt = descriptor.modifiedAt {
                writeU64(&data, 56, filetime(modifiedAt))
            }
            if let size = descriptor.size {
                writeU32(&data, 64, UInt32(size >> 32))
                writeU32(&data, 68, UInt32(size & 0xFFFF_FFFF))
            }
            writeFixedUTF16LE(descriptor.relativePath, into: &data, offset: 72, maximumUnits: 259)
            body.append(contentsOf: data)
        }
        return body
    }

    static func parseFileList(_ body: [UInt8]) -> [FileDescriptor]? {
        guard body.count >= 4 else { return nil }
        let count = Int(readU32(body, 0))
        guard count <= ClipboardTransferLimits.maximumItemCount,
              body.count == 4 + count * fileDescriptorSize else {
            return nil
        }

        var descriptors: [FileDescriptor] = []
        descriptors.reserveCapacity(count)
        for index in 0..<count {
            let offset = 4 + index * fileDescriptorSize
            let flags = readU32(body, offset)
            let attributes = readU32(body, offset + 36)
            let size: UInt64? = flags & 0x0000_0040 != 0
                ? UInt64(readU32(body, offset + 68)) | UInt64(readU32(body, offset + 64)) << 32
                : nil
            let modifiedAt = flags & 0x0000_0020 != 0
                ? dateFromFiletime(readU64(body, offset + 56))
                : nil
            let name = readFixedUTF16LE(body, offset: offset + 72, maximumUnits: 260)
            descriptors.append(
                FileDescriptor(
                    relativePath: name,
                    isDirectory: attributes & 0x10 != 0,
                    size: size,
                    modifiedAt: modifiedAt
                )
            )
        }
        return descriptors
    }

    static func encodeUnicodeText(_ text: String) -> [UInt8] {
        var data: [UInt8] = []
        data.appendUTF16LE(text)
        data.appendU16(0)
        return data
    }

    static func decodeUnicodeText(_ data: [UInt8]) -> String? {
        guard data.count.isMultiple(of: 2) else { return nil }
        var units: [UInt16] = []
        for offset in stride(from: 0, to: data.count, by: 2) {
            let unit = readU16(data, offset)
            if unit == 0 { break }
            units.append(unit)
        }
        return String(decoding: units, as: UTF16.self)
    }

    static func encodeHTML(_ html: String) -> [UInt8] {
        let fragmentPrefix = "<!--StartFragment-->"
        let fragmentSuffix = "<!--EndFragment-->"
        let document = "<html><body>\(fragmentPrefix)\(html)\(fragmentSuffix)</body></html>"
        let template = "Version:1.0\r\nStartHTML:%010d\r\nEndHTML:%010d\r\nStartFragment:%010d\r\nEndFragment:%010d\r\n"
        let placeholder = String(format: template, 0, 0, 0, 0)
        let startHTML = placeholder.utf8.count
        let startFragment = startHTML + "<html><body>\(fragmentPrefix)".utf8.count
        let endFragment = startFragment + html.utf8.count
        let endHTML = startHTML + document.utf8.count
        let header = String(format: template, startHTML, endHTML, startFragment, endFragment)
        return Array((header + document).utf8) + [0]
    }

    static func decodeHTML(_ data: [UInt8]) -> String? {
        guard let raw = String(bytes: data.prefix { $0 != 0 }, encoding: .utf8) else { return nil }
        if let start = headerOffset(named: "StartFragment", in: raw),
           let end = headerOffset(named: "EndFragment", in: raw),
           start >= 0, end >= start,
           let startIndex = raw.utf8.index(raw.utf8.startIndex, offsetBy: start, limitedBy: raw.utf8.endIndex),
           let endIndex = raw.utf8.index(raw.utf8.startIndex, offsetBy: end, limitedBy: raw.utf8.endIndex) {
            return String(decoding: raw.utf8[startIndex..<endIndex], as: UTF8.self)
        }
        if let range = raw.range(of: "<html", options: .caseInsensitive) {
            return String(raw[range.lowerBound...])
        }
        return raw
    }

    static func readU16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    static func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    static func readU64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        UInt64(readU32(bytes, offset)) | UInt64(readU32(bytes, offset + 4)) << 32
    }

    static func bytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }

    private static func writeU32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private static func writeU64(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt64) {
        for index in 0..<8 {
            bytes[offset + index] = UInt8((value >> (8 * index)) & 0xFF)
        }
    }

    private static func writeFixedUTF16LE(
        _ value: String,
        into bytes: inout [UInt8],
        offset: Int,
        maximumUnits: Int
    ) {
        var cursor = offset
        for unit in value.utf16.prefix(maximumUnits) {
            bytes[cursor] = UInt8(unit & 0xFF)
            bytes[cursor + 1] = UInt8(unit >> 8)
            cursor += 2
        }
    }

    private static func readFixedUTF16LE(_ bytes: [UInt8], offset: Int, maximumUnits: Int) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(maximumUnits)
        for index in 0..<maximumUnits {
            let unit = readU16(bytes, offset + index * 2)
            if unit == 0 { break }
            units.append(unit)
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func filetime(_ date: Date) -> UInt64 {
        UInt64(max(0, (date.timeIntervalSince1970 + 11_644_473_600) * 10_000_000))
    }

    private static func dateFromFiletime(_ value: UInt64) -> Date? {
        guard value != 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value) / 10_000_000 - 11_644_473_600)
    }

    private static func headerOffset(named name: String, in html: String) -> Int? {
        guard let range = html.range(of: "\(name):") else { return nil }
        let suffix = html[range.upperBound...]
        let digits = suffix.prefix { $0.isNumber }
        return Int(digits)
    }
}

private extension Array where Element == UInt8 {
    mutating func appendU64(_ value: UInt64) {
        appendU32(UInt32(value & 0xFFFF_FFFF))
        appendU32(UInt32(value >> 32))
    }

    mutating func appendUTF16LE(_ value: String) {
        for unit in value.utf16 {
            appendU16(unit)
        }
    }
}
