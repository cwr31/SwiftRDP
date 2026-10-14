import NIOCore

/// MS-RDPBCGR Client Info extended information and ARC_CS_PRIVATE_PACKET.
enum AutoReconnectPDU {
    struct ClientPacket {
        let logonID: UInt32
        let securityVerifier: [UInt8]
    }

    static func parseClientPacket(fromClientInfo bytes: [UInt8]) -> ClientPacket? {
        var buffer = ByteBuffer(bytes: bytes)
        guard buffer.readUInt32() != nil, let flags = buffer.readUInt32() else { return nil }
        var stringBytes = 0
        let terminatorBytes = flags & 0x10 != 0 ? 2 : 1 // INFO_UNICODE
        for _ in 0..<5 {
            guard let length = buffer.readUInt16() else { return nil }
            stringBytes += Int(length) + terminatorBytes
        }
        guard buffer.readableBytes >= stringBytes else { return nil }
        buffer.moveReaderIndex(forwardBy: stringBytes)

        guard buffer.readUInt16() != nil, // clientAddressFamily
              skipString(in: &buffer, limit: 80), // cbClientAddress + clientAddress
              skipString(in: &buffer, limit: 512), // cbClientDir + clientDir
              buffer.readableBytes >= 172 + 4 + 4 + 2 else { return nil }
        buffer.moveReaderIndex(forwardBy: 172 + 4 + 4) // time zone, session ID, performance flags
        guard buffer.readUInt16() == 28,
              buffer.readUInt32() == 28,
              buffer.readUInt32() == 1,
              let logonID = buffer.readUInt32(),
              let verifier = buffer.readBytes(length: 16) else { return nil }
        return ClientPacket(logonID: logonID, securityVerifier: verifier)
    }

    private static func skipString(in buffer: inout ByteBuffer, limit: Int) -> Bool {
        guard let length = buffer.readUInt16(), length <= limit,
              buffer.readableBytes >= Int(length) else { return false }
        buffer.moveReaderIndex(forwardBy: Int(length))
        return true
    }
}
