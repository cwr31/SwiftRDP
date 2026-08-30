import Foundation

/// Share control / data headers and P0 capability exchange PDUs (MS-RDPBCGR).
/// Demand Active capability set layout follows MS-RDPBCGR.
public enum SharePDU {
    public struct ConfirmActiveCapabilities: Equatable, Sendable {
        public let surfaceCommandFlags: UInt32?
        public let maxUnacknowledgedFrameCount: UInt32?
        public let largePointerSupportFlags: UInt16?
        public let multifragmentMaxRequestSize: UInt32?

        public var hasSurfaceCommands: Bool {
            surfaceCommandFlags.map { $0 != 0 } ?? false
        }

        /// Large pointers require both capability sets and a sufficiently large request size.
        public var maximumPointerDimension: Int {
            guard let flags = largePointerSupportFlags,
                  flags & 0x0003 != 0,
                  let maxRequestSize = multifragmentMaxRequestSize,
                  maxRequestSize >= 38_055
            else { return 32 }
            return 96
        }
    }

    public static let streamLow: UInt8 = 1

    // Wire pduType = (type & 0x0F) | 0x10 (PDU type | version)
    public static let pduTypeDemandActive: UInt16 = 0x1
    public static let pduTypeConfirmActive: UInt16 = 0x3
    public static let pduTypeData: UInt16 = 0x7
    public static let pduTypeDeactivateAll: UInt16 = 0x6

    public static let pdutype2Synchronize: UInt8 = 0x1F
    public static let pdutype2Control: UInt8 = 0x14
    public static let pdutype2Fontlist: UInt8 = 0x27
    public static let pdutype2Fontmap: UInt8 = 0x28
    public static let pdutype2Input: UInt8 = 0x1C
    public static let pdutype2Update: UInt8 = 0x02
    public static let pdutype2Pointer: UInt8 = 0x1B
    public static let pdutype2RefreshRect: UInt8 = 0x21
    public static let pdutype2SuppressOutput: UInt8 = 0x23
    public static let pdutype2ShutdownRequest: UInt8 = 0x24
    public static let pdutype2ShutdownDenied: UInt8 = 0x25
    public static let pdutype2SaveSessionInfo: UInt8 = 0x26
    public static let pdutype2MonitorLayout: UInt8 = 0x37

    public static let ctrlActionCooperate: UInt16 = 0x0004
    public static let ctrlActionRequestControl: UInt16 = 0x0001
    public static let ctrlActionGrantedControl: UInt16 = 0x0002

    public static let updateTypeBitmap: UInt16 = 0x0001
    public static let updateTypeOrders: UInt16 = 0x0000
    public static let updateTypePalette: UInt16 = 0x0002
    public static let updateTypeSynchronize: UInt16 = 0x0003

    // Capability set types (MS-RDPBCGR CAPSET_TYPE_*)
    public static let capsetGeneral: UInt16 = 0x0001
    public static let capsetBitmap: UInt16 = 0x0002
    public static let capsetOrder: UInt16 = 0x0003
    public static let capsetPointer: UInt16 = 0x0008
    public static let capsetShare: UInt16 = 0x0009
    public static let capsetSound: UInt16 = 0x000C
    public static let capsetInput: UInt16 = 0x000D
    public static let capsetFont: UInt16 = 0x000E
    public static let capsetVirtualChannel: UInt16 = 0x0014
    public static let capsetCompDesk: UInt16 = 0x0019
    public static let capsetMultifragment: UInt16 = 0x001A
    public static let capsetLargePointer: UInt16 = 0x001B
    public static let capsetSurfaceCommands: UInt16 = 0x001C
    public static let capsetBitmapCodecs: UInt16 = 0x001D
    public static let capsetFrameAck: UInt16 = 0x001E

    public static func shareControlHeader(type: UInt16, source: UInt16, pduLength: UInt16) -> [UInt8] {
        var h: [UInt8] = []
        h.appendU16(pduLength)
        // Wire: UInt16(pduType | 0x10)
        h.appendU16((type & 0x0F) | 0x10)
        h.appendU16(source)
        return h
    }

    public static func shareDataHeader(
        shareId: UInt32,
        streamId: UInt8,
        uncompressedLength: UInt16,
        pduType2: UInt8,
        compressedType: UInt8 = 0,
        compressedLength: UInt16 = 0
    ) -> [UInt8] {
        var h: [UInt8] = []
        h.appendU32(shareId)
        h.append(0) // pad1
        h.append(streamId)
        h.appendU16(uncompressedLength)
        h.append(pduType2)
        h.append(compressedType)
        h.appendU16(compressedLength)
        return h
    }

    // MARK: Demand Active

    /// shareId: `0x10000 + mcsUserId`
    /// source: MCS userId (pduSource)
    /// sourceDescriptor: exactly `"RDP\0"` (4 bytes)
    public static func buildDemandActive(
        shareId: UInt32,
        channelId: UInt16,
        sourceDescriptor: String = "RDP",
        width: Int,
        height: Int
    ) -> [UInt8] {
        // Write "RDP" (4 bytes, includes trailing NUL)
        var src = Array(sourceDescriptor.utf8)
        if src.count >= 4 {
            src = Array(src.prefix(4))
        } else {
            while src.count < 4 { src.append(0) }
        }

        let caps = buildCapabilitySets(width: width, height: height)
        let numberCapabilities = numberOfCapSets(in: caps)
        let combinedLen = 2 + 2 + caps.count // numberCapabilities + pad + sets

        var body: [UInt8] = []
        body.appendU32(shareId)
        body.appendU16(UInt16(src.count)) // lengthSourceDescriptor (always 4)
        body.appendU16(UInt16(combinedLen))
        body.append(contentsOf: src)
        body.appendU16(UInt16(numberCapabilities))
        body.appendU16(0) // pad2Octets
        body.append(contentsOf: caps)
        body.appendU32(0) // sessionId

        var pdu = shareControlHeader(
            type: pduTypeDemandActive,
            source: channelId, // pduSource = MCS user id
            pduLength: UInt16(6 + body.count)
        )
        pdu.append(contentsOf: body)
        let len = UInt16(pdu.count)
        pdu[0] = UInt8(len & 0xFF)
        pdu[1] = UInt8((len >> 8) & 0xFF)
        return pdu
    }

    private static func numberOfCapSets(in data: [UInt8]) -> Int {
        var o = 0
        var n = 0
        while o + 4 <= data.count {
            let length = Int(UInt16(data[o + 2]) | UInt16(data[o + 3]) << 8)
            guard length >= 4, o + length <= data.count else { break }
            o += length
            n += 1
        }
        return n
    }

    /// Server Demand Active: 15 capability sets (no glyph/activation/control/colorCache).
    public static func buildCapabilitySets(width: Int, height: Int) -> [UInt8] {
        var out: [UInt8] = []
        out += capGeneral()
        out += capBitmap(width: width, height: height)
        out += capOrder()
        out += capPointer()
        out += capInput()
        out += capVirtualChannel()
        out += capShare()
        out += capFont()
        out += capMultifragment(width: width, height: height)
        out += capLargePointer()
        out += capCompDesk()
        out += capSurfaceCommands()
        out += capBitmapCodecs()
        out += capFrameAck()
        out += capSound()
        return out
    }

    private static func capSet(_ type: UInt16, _ body: [UInt8]) -> [UInt8] {
        var o: [UInt8] = []
        o.appendU16(type)
        o.appendU16(UInt16(body.count + 4))
        o.append(contentsOf: body)
        return o
    }

    private static func capGeneral() -> [UInt8] {
        // Defaults: FastPathOutput | LongCredentials | SaltedChecksum | NoBitmapCompressionHdr
        // + refreshRect + suppressOutput
        let extraFlags: UInt16 =
            0x0001 | // FASTPATH_OUTPUT_SUPPORTED
            0x0004 | // LONG_CREDENTIALS_SUPPORTED
            0x0010 | // ENC_SALTED_CHECKSUM
            0x0400 // NO_BITMAP_COMPRESSION_HDR
        var b: [UInt8] = []
        b.appendU16(1) // osMajorType OSMAJORTYPE_WINDOWS
        b.appendU16(3) // osMinorType OSMINORTYPE_WINDOWS_NT
        b.appendU16(0x0200) // protocolVersion TS_CAPS_PROTOCOLVERSION
        b.appendU16(0) // pad2OctetsA
        b.appendU16(0) // generalCompressionTypes
        b.appendU16(extraFlags)
        b.appendU16(0) // updateCapabilityFlag
        b.appendU16(0) // remoteUnshareFlag
        b.appendU16(0) // generalCompressionLevel
        b.append(1) // refreshRectSupport
        b.append(1) // suppressOutputSupport
        return capSet(capsetGeneral, b)
    }

    private static func capBitmap(width: Int, height: Int) -> [UInt8] {
        // DRAW_ALLOW_SKIP_ALPHA | DRAW_ALLOW_DYNAMIC_COLOR_FIDELITY
        let drawingFlags: UInt8 = 0x01 | 0x02
        var b: [UInt8] = []
        b.appendU16(32) // preferredBitsPerPixel (ColorDepth=32)
        b.appendU16(1) // receive1BitPerPixel
        b.appendU16(1) // receive4BitsPerPixel
        b.appendU16(1) // receive8BitsPerPixel
        b.appendU16(UInt16(width))
        b.appendU16(UInt16(height))
        b.appendU16(0) // pad2Octets
        b.appendU16(1) // desktopResizeFlag
        b.appendU16(1) // bitmapCompressionFlag
        b.append(0) // highColorFlags (1 byte) — was wrongly UInt16
        b.append(drawingFlags) // drawingFlags (1 byte)
        b.appendU16(1) // multipleRectangleSupport
        b.appendU16(0) // pad2OctetsB
        return capSet(capsetBitmap, b)
    }

    private static func capOrder() -> [UInt8] {
        // No GDI Primary Drawing Orders are emitted — advertise empty orderSupport.
        var b = [UInt8](repeating: 0, count: 84)
        var o = 16
        o += 4 // pad4OctetsA
        b[o] = 1; b[o + 1] = 0; o += 2 // desktopSaveXGranularity
        b[o] = 20; b[o + 1] = 0; o += 2 // desktopSaveYGranularity
        o += 2 // pad2OctetsA
        b[o] = 1; b[o + 1] = 0; o += 2 // maximumOrderLevel
        o += 2 // numberFonts
        // orderFlags: NEGOTIATEORDERSUPPORT only (no drawing orders claimed)
        let orderFlags: UInt16 = 0x0002
        b[o] = UInt8(orderFlags & 0xFF)
        b[o + 1] = UInt8((orderFlags >> 8) & 0xFF)
        o += 2
        // orderSupport[32] left zero
        o += 32
        o += 2 // textFlags
        o += 2 // orderSupportExFlags
        o += 4 // pad4OctetsB
        // desktopSaveSize = 0 (unused without orders)
        return capSet(capsetOrder, b)
    }

    private static func capPointer() -> [UInt8] {
        var b: [UInt8] = []
        b.appendU16(1) // colorPointerFlag (ignored, always assumed TRUE)
        b.appendU16(25) // colorPointerCacheSize (server default)
        b.appendU16(25) // pointerCacheSize (server default)
        return capSet(capsetPointer, b)
    }

    private static func capInput() -> [UInt8] {
        // inputFlags + pad + keyboard* + imeFileName[64]
        // MouseHandler injects PTRFLAGS_HWHEEL and relative deltas (TS_RELPOINTER_EVENT).
        let inputFlags: UInt16 =
            0x0001 | // INPUT_FLAG_SCANCODES
            0x0004 | // INPUT_FLAG_MOUSEX
            0x0008 | // INPUT_FLAG_FASTPATH_INPUT
            0x0010 | // INPUT_FLAG_UNICODE
            0x0020 | // INPUT_FLAG_FASTPATH_INPUT2
            0x0080 | // INPUT_FLAG_MOUSE_RELATIVE (MS-RDPBCGR; requires RDP ≥ 10.12)
            0x0100   // TS_INPUT_FLAG_MOUSE_HWHEEL
        var b: [UInt8] = []
        b.appendU16(inputFlags)
        b.appendU16(0) // pad2OctetsA
        b.appendU32(0) // keyboardLayout
        b.appendU32(4) // keyboardType IBM_ENHANCED
        b.appendU32(0) // keyboardSubType
        b.appendU32(12) // keyboardFunctionKeys
        b.append(contentsOf: [UInt8](repeating: 0, count: 64)) // imeFileName
        return capSet(capsetInput, b)
    }

    private static func capVirtualChannel() -> [UInt8] {
        var b: [UInt8] = []
        b.appendU32(0) // flags (VCFlags)
        b.appendU32(16_256) // VCChunkSize CHANNEL_CHUNK_MAX_LENGTH (server)
        return capSet(capsetVirtualChannel, b)
    }

    private static func capSound() -> [UInt8] {
        var b: [UInt8] = []
        b.appendU16(0x0001) // SOUND_BEEPS_FLAG
        b.appendU16(0) // pad2OctetsA
        return capSet(capsetSound, b)
    }

    private static func capShare() -> [UInt8] {
        var b: [UInt8] = []
        b.appendU16(0x03EA) // nodeId (server mode)
        b.appendU16(0) // pad2Octets
        return capSet(capsetShare, b)
    }

    private static func capFont() -> [UInt8] {
        var b: [UInt8] = []
        b.appendU16(0x0001) // FONTSUPPORT_FONTLIST
        b.appendU16(0)
        return capSet(capsetFont, b)
    }

    private static func capMultifragment(width: Int, height: Int) -> [UInt8] {
        // server: (tileNumX * tileNumY + 1) * 16384
        let tileNumX = (width + 63) / 64
        let tileNumY = (height + 63) / 64
        let maxRequest = UInt32((tileNumX * tileNumY + 1) * 16_384)
        var b: [UInt8] = []
        b.appendU32(maxRequest)
        return capSet(capsetMultifragment, b)
    }

    private static func capLargePointer() -> [UInt8] {
        var b: [UInt8] = []
        b.appendU16(0x0001 | 0x0002) // 96x96 | 384x384
        return capSet(capsetLargePointer, b)
    }

    private static func capCompDesk() -> [UInt8] {
        var b: [UInt8] = []
        b.appendU16(0) // COMPDESK_NOT_SUPPORTED 
        return capSet(capsetCompDesk, b)
    }

    private static func capSurfaceCommands() -> [UInt8] {
        // SET_SURFACE_BITS | FRAME_MARKER | STREAM_SURFACE_BITS
        let cmdFlags: UInt32 = 0x0000_0002 | 0x0000_0010 | 0x0000_0040
        var b: [UInt8] = []
        b.appendU32(cmdFlags)
        b.appendU32(0) // reserved
        return capSet(capsetSurfaceCommands, b)
    }

    private static func capBitmapCodecs() -> [UInt8] {
        // server with RemoteFxCodec: GUID + codecID=0 + propertiesLength=4 + reserved=0
        // CODEC_GUID_REMOTEFX: 76772F12-BD72-4463-AFB3-B73C9C6F7886
        let guid: [UInt8] = [
            0x12, 0x2F, 0x77, 0x76, 0x72, 0xBD, 0x63, 0x44,
            0xAF, 0xB3, 0xB7, 0x3C, 0x9C, 0x6F, 0x78, 0x86
        ]
        var b: [UInt8] = []
        b.append(1) // bitmapCodecCount
        b.append(contentsOf: guid)
        b.append(0) // codecID (server: defined by client)
        b.appendU16(4) // codecPropertiesLength
        b.appendU32(0) // reserved
        return capSet(capsetBitmapCodecs, b)
    }

    private static func capFrameAck() -> [UInt8] {
        var b: [UInt8] = []
        // Server-to-client value: number of in-flight FRAME_ACK PDUs the server
        // can accept (distinct from GFX unacked send window).
        b.appendU32(8)
        return capSet(capsetFrameAck, b)
    }

    // MARK: Data PDUs

    public static func buildSynchronize(shareId: UInt32, targetUser: UInt16 = 1002) -> [UInt8] {
        var data: [UInt8] = []
        data.appendU16(1) // messageType SYNCMSGTYPE_SYNC
        data.appendU16(targetUser)
        return wrapDataPDU(shareId: shareId, pduType2: pdutype2Synchronize, payload: data)
    }

    public static func buildControl(shareId: UInt32, action: UInt16, grantId: UInt16 = 0, controlId: UInt32 = 0) -> [UInt8] {
        var data: [UInt8] = []
        data.appendU16(action)
        data.appendU16(grantId)
        data.appendU32(controlId)
        return wrapDataPDU(shareId: shareId, pduType2: pdutype2Control, payload: data)
    }

    public static func buildFontMap(shareId: UInt32) -> [UInt8] {
        var data: [UInt8] = []
        data.appendU16(0)
        data.appendU16(0)
        data.appendU16(0x0003) // FONTMAP_FIRST | FONTMAP_LAST
        data.appendU16(0)
        return wrapDataPDU(shareId: shareId, pduType2: pdutype2Fontmap, payload: data)
    }

    /// PDUTYPE2_SHUTDOWN_DENIED
    public static func buildShutdownDenied(shareId: UInt32) -> [UInt8] {
        wrapDataPDU(shareId: shareId, pduType2: pdutype2ShutdownDenied, payload: [])
    }

    /// TS_SAVE_SESSION_INFO_PDU_DATA with INFO_TYPE_LOGON_PLAIN_NOTIFY.
    /// Layout: MS-RDPBCGR 2.2.10.1.1.3.
    public static func buildSaveSessionInfoPlainNotify(shareId: UInt32) -> [UInt8] {
        var payload: [UInt8] = []
        payload.appendU32(0x0000_0002) // INFO_TYPE_LOGON_PLAIN_NOTIFY
        payload.append(contentsOf: [UInt8](repeating: 0, count: 576)) // TS_PLAIN_NOTIFY.Pad
        return wrapDataPDU(shareId: shareId, pduType2: pdutype2SaveSessionInfo, payload: payload)
    }

    /// INFO_TYPE_LOGON_EXTENDED_INF with LogonId + Auto-Reconnect Cookie (ARC).
    /// MS-RDPBCGR 2.2.10.1.1.4 / 2.2.10.1.1.4.1 (LOGON_INFO_FIELD + ARC_SC_PRIVATE_PACKET).
    public static func buildSaveSessionInfoLogonExtended(
        shareId: UInt32,
        logonId: UInt32,
        autoReconnectCookie: [UInt8]
    ) -> [UInt8] {
        precondition(autoReconnectCookie.count == 16, "ARC cookie must be 16 bytes")
        // TS_LOGON_INFO_EXTENDED: Length(2) + FieldsPresent(4) + LogonFields…
        // FieldsPresent: LOGON_EX_AUTORECONNECTCOOKIE = 0x00000002
        var logonFields: [UInt8] = []
        // ARC_SC_PRIVATE_PACKET: cbLen(4)=0x1C, Version(4)=1, LogonId(4), ArcRandomBits(16)
        var arc: [UInt8] = []
        arc.appendU32(0x0000_001C)
        arc.appendU32(1)
        arc.appendU32(logonId)
        arc.append(contentsOf: autoReconnectCookie)
        logonFields.appendU32(UInt32(arc.count))
        logonFields.append(contentsOf: arc)

        var extended: [UInt8] = []
        let length = UInt16(2 + 4 + logonFields.count)
        extended.appendU16(length)
        extended.appendU32(0x0000_0002) // LOGON_EX_AUTORECONNECTCOOKIE
        extended.append(contentsOf: logonFields)

        var payload: [UInt8] = []
        payload.appendU32(0x0000_0004) // INFO_TYPE_LOGON_EXTENDED_INF
        payload.append(contentsOf: extended)
        return wrapDataPDU(shareId: shareId, pduType2: pdutype2SaveSessionInfo, payload: payload)
    }

    /// PDUTYPE2_MONITOR_LAYOUT_PDU — single primary monitor covering the desktop.
    public static func buildMonitorLayout(shareId: UInt32, width: Int, height: Int) -> [UInt8] {
        let w = max(1, width)
        let h = max(1, height)
        var data: [UInt8] = []
        data.appendU32(1) // monitorCount
        // TS_MONITOR_DEF: left, top, right, bottom, flags (MONITOR_PRIMARY=1)
        data.appendU32(0)
        data.appendU32(0)
        data.appendU32(UInt32(w - 1))
        data.appendU32(UInt32(h - 1))
        data.appendU32(1)
        return wrapDataPDU(shareId: shareId, pduType2: pdutype2MonitorLayout, payload: data, source: 0)
    }

    // MS-RDPBCGR Pointer Update (PDUTYPE2_POINTER = 0x1B)
    public static let ptrMsgTypeSystem: UInt16 = 0x0001
    public static let ptrMsgTypePosition: UInt16 = 0x0003
    public static let ptrMsgTypeColor: UInt16 = 0x0006
    public static let ptrMsgTypeCached: UInt16 = 0x0007
    public static let ptrMsgTypePointer: UInt16 = 0x0008
    public static let sysPtrNull: UInt32 = 0
    public static let sysPtrDefault: UInt32 = 0x0000_7F00

    /// TS_SYSTEMPOINTERATTRIBUTE — show the default system cursor on the client.
    public static func buildSystemPointer(shareId: UInt32, systemPointerType: UInt32 = sysPtrDefault) -> [UInt8] {
        var data: [UInt8] = []
        data.appendU16(ptrMsgTypeSystem)
        data.appendU32(systemPointerType)
        return wrapDataPDU(shareId: shareId, pduType2: pdutype2Pointer, payload: data)
    }

    /// TS_POINTERPOSATTRIBUTE — client-side cursor position (RDP desktop coords).
    public static func buildPointerPosition(shareId: UInt32, x: Int, y: Int) -> [UInt8] {
        var data: [UInt8] = []
        data.appendU16(ptrMsgTypePosition)
        data.appendU16(UInt16(clamping: max(0, x)))
        data.appendU16(UInt16(clamping: max(0, y)))
        return wrapDataPDU(shareId: shareId, pduType2: pdutype2Pointer, payload: data)
    }

    public static func wrapDataPDU(shareId: UInt32, pduType2: UInt8, payload: [UInt8], source: UInt16 = 0x03EA) -> [UInt8] {
        var sd: [UInt8] = []
        sd.appendU32(shareId)
        sd.append(0)
        sd.append(streamLow)
        let unclen = UInt16(4 + 1 + 1 + 2 + 1 + 1 + 2 + payload.count)
        sd.appendU16(unclen)
        sd.append(pduType2)
        sd.append(0)
        sd.appendU16(0)
        sd.append(contentsOf: payload)

        let total = 6 + sd.count
        var pdu = shareControlHeader(type: pduTypeData, source: source, pduLength: UInt16(total))
        pdu.append(contentsOf: sd)
        let len = UInt16(pdu.count)
        pdu[0] = UInt8(len & 0xFF)
        pdu[1] = UInt8((len >> 8) & 0xFF)
        return pdu
    }

    /// Slow-path bitmap update (single uncompressed 24-bpp BGR rectangle, bottom-up).
    /// Returns empty if the rectangle cannot fit RDP UInt16 length/coord fields (avoids trap).
    public static func buildBitmapUpdate(
        shareId: UInt32,
        destLeft: Int,
        destTop: Int,
        destRight: Int,
        destBottom: Int,
        width: Int,
        height: Int,
        bgrBottomUp: [UInt8]
    ) -> [UInt8] {
        // MS-RDPBCGR bitmapDataLength is UINT16 — never trap on large tiles.
        guard width > 0, height > 0,
              width <= Int(UInt16.max), height <= Int(UInt16.max),
              destLeft >= 0, destTop >= 0,
              destRight >= destLeft, destBottom >= destTop,
              destRight <= Int(UInt16.max), destBottom <= Int(UInt16.max),
              bgrBottomUp.count <= Int(UInt16.max),
              !bgrBottomUp.isEmpty else {
            return []
        }
        var bitmapData: [UInt8] = []
        bitmapData.appendU16(UInt16(destLeft))
        bitmapData.appendU16(UInt16(destTop))
        bitmapData.appendU16(UInt16(destRight))
        bitmapData.appendU16(UInt16(destBottom))
        bitmapData.appendU16(UInt16(width))
        bitmapData.appendU16(UInt16(height))
        bitmapData.appendU16(24) // bitsPerPixel
        bitmapData.appendU16(0) // flags uncompressed
        bitmapData.appendU16(UInt16(bgrBottomUp.count))
        bitmapData.append(contentsOf: bgrBottomUp)

        var update: [UInt8] = []
        update.appendU16(updateTypeBitmap)
        update.appendU16(1) // numberRectangles
        update.append(contentsOf: bitmapData)

        let pdu = wrapDataPDU(shareId: shareId, pduType2: pdutype2Update, payload: update)
        // Share Control totalLength is also UINT16.
        guard pdu.count <= Int(UInt16.max) else { return [] }
        return pdu
    }

    public static func parseDataPDU(_ data: [UInt8]) -> (pduType2: UInt8, payload: [UInt8])? {
        guard data.count >= 18 else { return nil }
        let pduType = UInt16(data[2]) | UInt16(data[3]) << 8
        let type = pduType & 0x0F
        guard type == pduTypeData else { return nil }
        let t2 = data[14]
        let payload = Array(data[18...])
        return (t2, payload)
    }

    /// Capabilities the client selected in Confirm Active (MS-RDPBCGR 2.2.1.13.2).
    public static func parseConfirmActiveCapabilities(
        _ shareControl: [UInt8]
    ) -> ConfirmActiveCapabilities {
        // Share Control (6) + shareId(4) + originator(2) + lengthSourceDescriptor(2) + lengthCombinedCapabilities(2)
        guard shareControl.count >= 16 else {
            return ConfirmActiveCapabilities(
                surfaceCommandFlags: nil,
                maxUnacknowledgedFrameCount: nil,
                largePointerSupportFlags: nil,
                multifragmentMaxRequestSize: nil
            )
        }
        // originatorId is at 10; lengthSourceDescriptor follows it at 12.
        let srcLen = Int(UInt16(shareControl[12]) | UInt16(shareControl[13]) << 8)
        var o = 16 + srcLen
        guard o + 4 <= shareControl.count else {
            return ConfirmActiveCapabilities(
                surfaceCommandFlags: nil,
                maxUnacknowledgedFrameCount: nil,
                largePointerSupportFlags: nil,
                multifragmentMaxRequestSize: nil
            )
        }
        let numberCapabilities = Int(UInt16(shareControl[o]) | UInt16(shareControl[o + 1]) << 8)
        o += 4 // numberCapabilities + pad2Octets
        var surfaceCommandFlags: UInt32?
        var maxUnacknowledgedFrameCount: UInt32?
        var largePointerSupportFlags: UInt16?
        var multifragmentMaxRequestSize: UInt32?
        for _ in 0..<numberCapabilities {
            guard o + 4 <= shareControl.count else { break }
            let capType = UInt16(shareControl[o]) | UInt16(shareControl[o + 1]) << 8
            let capLen = Int(UInt16(shareControl[o + 2]) | UInt16(shareControl[o + 3]) << 8)
            guard capLen >= 4, o + capLen <= shareControl.count else { break }
            if capType == capsetSurfaceCommands, capLen >= 8 {
                surfaceCommandFlags = UInt32(shareControl[o + 4])
                    | UInt32(shareControl[o + 5]) << 8
                    | UInt32(shareControl[o + 6]) << 16
                    | UInt32(shareControl[o + 7]) << 24
            } else if capType == capsetFrameAck, capLen >= 8 {
                maxUnacknowledgedFrameCount = UInt32(shareControl[o + 4])
                    | UInt32(shareControl[o + 5]) << 8
                    | UInt32(shareControl[o + 6]) << 16
                    | UInt32(shareControl[o + 7]) << 24
            } else if capType == capsetLargePointer, capLen >= 6 {
                largePointerSupportFlags = UInt16(shareControl[o + 4])
                    | UInt16(shareControl[o + 5]) << 8
            } else if capType == capsetMultifragment, capLen >= 8 {
                multifragmentMaxRequestSize = UInt32(shareControl[o + 4])
                    | UInt32(shareControl[o + 5]) << 8
                    | UInt32(shareControl[o + 6]) << 16
                    | UInt32(shareControl[o + 7]) << 24
            }
            o += capLen
        }
        return ConfirmActiveCapabilities(
            surfaceCommandFlags: surfaceCommandFlags,
            maxUnacknowledgedFrameCount: maxUnacknowledgedFrameCount,
            largePointerSupportFlags: largePointerSupportFlags,
            multifragmentMaxRequestSize: multifragmentMaxRequestSize
        )
    }

    /// Confirm Active: true when the client advertises usable Surface Commands.
    public static func confirmActiveHasSurfaceCommands(_ shareControl: [UInt8]) -> Bool {
        parseConfirmActiveCapabilities(shareControl).hasSurfaceCommands
    }
}
