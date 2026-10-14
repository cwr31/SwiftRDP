import NIOCore

/// MS-RDPBCGR 2.2.15 and MS-RDPEMT 2.2. All tunnel traffic is inside TLS.
enum MultitransportPDU {
    static let reliableUDP: UInt32 = 1
    static let softSync: UInt32 = 0x200
    static let capabilities = reliableUDP | softSync

    static func initiate(requestID: UInt32, cookie: [UInt8]) -> [UInt8] {
        precondition(cookie.count == 16)
        var bytes: [UInt8] = [0x02, 0, 0, 0] // SEC_TRANSPORT_REQ, flagsHi
        bytes.appendU32(requestID)
        bytes.appendU16(1) // INITITATE_REQUEST_PROTOCOL_UDPFECR
        bytes.appendU16(0)
        bytes += cookie
        return bytes
    }

    static func response(_ bytes: [UInt8]) -> (requestID: UInt32, result: UInt32)? {
        var b = ByteBuffer(bytes: bytes)
        guard b.readInteger(endianness: .little, as: UInt16.self) == 4, // SEC_TRANSPORT_RSP
              b.readInteger(endianness: .little, as: UInt16.self) == 0,
              let id = b.readInteger(endianness: .little, as: UInt32.self),
              let result = b.readInteger(endianness: .little, as: UInt32.self), b.readableBytes == 0
        else { return nil }
        return (id, result)
    }

    enum Action: UInt8 { case createRequest = 0, createResponse = 1, data = 2 }

    struct TunnelMessage {
        let action: Action
        var subheaders: [(type: UInt8, bytes: [UInt8])] = []
        let payload: [UInt8]

        func encode() -> [UInt8] {
            let headerLength = 4 + subheaders.reduce(0) { $0 + 2 + $1.bytes.count }
            precondition(headerLength <= 255 && payload.count <= 65_535)
            var bytes: [UInt8] = [action.rawValue]
            bytes.appendU16(UInt16(payload.count))
            bytes.append(UInt8(headerLength))
            for h in subheaders {
                bytes.append(UInt8(h.bytes.count + 2))
                bytes.append(h.type)
                bytes += h.bytes
            }
            return bytes + payload
        }

        /// Consume one complete message; an incomplete TLS record does not advance the reader.
        static func read(from buffer: inout ByteBuffer) throws -> TunnelMessage? {
            guard buffer.readableBytes >= 4 else { return nil }
            let start = buffer.readerIndex
            guard let command = buffer.getInteger(at: start, as: UInt8.self),
                  command & 0xF0 == 0, let action = Action(rawValue: command),
                  let length = buffer.getInteger(at: start + 1, endianness: .little, as: UInt16.self),
                  let headerLength = buffer.getInteger(at: start + 3, as: UInt8.self),
                  headerLength >= 4
            else { throw RDPUDPError.malformedPacket }
            let total = Int(headerLength) + Int(length)
            guard buffer.readableBytes >= total else { return nil }
            buffer.moveReaderIndex(forwardBy: 4)
            var subheaders: [(UInt8, [UInt8])] = []
            while buffer.readerIndex < start + Int(headerLength) {
                guard let size = buffer.readInteger(as: UInt8.self), size >= 2,
                      buffer.readerIndex + Int(size) - 1 <= start + Int(headerLength),
                      let type = buffer.readInteger(as: UInt8.self),
                      let bytes = buffer.readBytes(length: Int(size) - 2)
                else { throw RDPUDPError.malformedPacket }
                subheaders.append((type, bytes))
            }
            return TunnelMessage(action: action, subheaders: subheaders,
                                 payload: buffer.readBytes(length: Int(length))!)
        }
    }

    static func softSyncRequest(channelID: UInt32) -> [UInt8] {
        var bytes: [UInt8] = [0x80, 0] // cmd, pad
        bytes.appendU32(18) // Length through end of channel list, excluding cmd + pad
        bytes.appendU16(3)  // TCP_FLUSHED | CHANNEL_LIST_PRESENT
        bytes.appendU16(1)  // NumberOfTunnels
        bytes.appendU32(reliableUDP)
        bytes.appendU16(1)  // NumberOfDVCs
        bytes.appendU32(channelID)
        return bytes
    }

    static func softSyncResponse(_ bytes: [UInt8]) -> [UInt32]? {
        var b = ByteBuffer(bytes: bytes)
        guard b.readInteger(as: UInt8.self) == 0x90,
              b.readInteger(as: UInt8.self) == 0,
              let count = b.readInteger(endianness: .little, as: UInt32.self), count <= 2,
              b.readableBytes == Int(count) * 4 else { return nil }
        return (0..<count).map { _ in b.readInteger(endianness: .little, as: UInt32.self)! }
    }

    static func authenticates(_ bytes: [UInt8], requestID: UInt32, cookie: [UInt8]) -> Bool {
        var b = ByteBuffer(bytes: bytes)
        guard b.readableBytes == 24, b.readInteger(endianness: .little, as: UInt32.self) == requestID,
              b.readInteger(endianness: .little, as: UInt32.self) == 0, let received = b.readBytes(length: 16)
        else { return false }
        return constantTimeEqual(received, cookie)
    }

    static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for i in lhs.indices { difference |= lhs[i] ^ rhs[i] }
        return difference == 0
    }
}
