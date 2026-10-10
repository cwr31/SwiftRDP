import Foundation

/// Stores complete protocol packets; consuming a packet never splits a TPKT.
struct OutboundWriteQueue {
    private struct Packet {
        var bytes: [UInt8]
        let endsMessage: Bool
        let isVideo: Bool
        let onWritten: RDPSocket.WriteCompletion?
    }
    private var storage: [Packet] = []
    private var head = 0
    private(set) var byteCount = 0
    private(set) var messageCount = 0
    private(set) var videoFrameCount = 0
    private(set) var controlByteCount = 0

    var isEmpty: Bool { head >= storage.count }
    var firstByteCount: Int { isEmpty ? 0 : storage[head].bytes.count }
    var firstIsVideo: Bool { !isEmpty && storage[head].isVideo }

    mutating func append(_ packets: [[UInt8]], isVideo: Bool = false, onWritten: RDPSocket.WriteCompletion? = nil) {
        guard !packets.isEmpty else { return }
        for (index, bytes) in packets.enumerated() {
            storage.append(Packet(
                bytes: bytes, endsMessage: index == packets.count - 1, isVideo: isVideo,
                onWritten: index == packets.count - 1 ? onWritten : nil
            ))
        }
        messageCount += 1
        if isVideo { videoFrameCount += 1 }
        else { controlByteCount += packets.reduce(0) { $0 + $1.count } }
        byteCount += packets.reduce(0) { $0 + $1.count }
    }

    mutating func popFirst() -> (bytes: [UInt8], onWritten: RDPSocket.WriteCompletion?)? {
        guard !isEmpty else { return nil }
        let packet = storage[head]
        storage[head].bytes = []
        head += 1
        byteCount -= packet.bytes.count
        if packet.endsMessage { messageCount -= 1 }
        if packet.isVideo {
            if packet.endsMessage { videoFrameCount -= 1 }
        } else {
            controlByteCount -= packet.bytes.count
        }
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head > 64, head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
        return (packet.bytes, packet.onWritten)
    }

    mutating func removeAll() { self = Self() }
}

/// A small byte budget prevents an encoded frame from becoming a TCP burst.
struct VideoBytePacer {
    private var lastRefillNanoseconds: UInt64?
    private var availableBytes = 0.0

    mutating func reserve(bytes: Int, bitrate: Int, now: UInt64) -> UInt64 {
        let bytesPerNanosecond = Double(max(bitrate, 1)) / 8_000_000_000
        let burst = max(Double(bytes), min(16_384, Double(max(bitrate, 1)) / 800))
        if let lastRefillNanoseconds {
            let elapsed = now >= lastRefillNanoseconds ? now - lastRefillNanoseconds : 0
            availableBytes = min(burst, availableBytes + Double(elapsed) * bytesPerNanosecond)
        } else {
            availableBytes = burst
        }
        lastRefillNanoseconds = now
        let missing = Double(bytes) - availableBytes
        guard missing <= 0 else {
            return UInt64(ceil(missing / bytesPerNanosecond))
        }
        availableBytes -= Double(bytes)
        return 0
    }
}
