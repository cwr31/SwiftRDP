import NIOCore

/// Reliable UDP2 byte stream. Owned by one event loop; time is supplied for deterministic
/// loss/reordering tests. Timers are armed at `nextDeadline`, never by a polling loop.
final class RDPUDP2Connection {
    static let logWindow: UInt8 = 10
    static let window = 1 << logWindow
    static let maximumBufferedBytes = 36 * 1024 * 1024
    static let keepaliveNanoseconds: UInt64 = 4_000_000_000
    static let idleNanoseconds: UInt64 = 16_000_000_000
    typealias Completion = @Sendable () -> Void

    struct Transmission {
        let bytes: [UInt8]
        var onSent: Completion?
    }
    private struct Write {
        var buffer: ByteBuffer
        let onSent: Completion?
    }
    private struct Segment {
        let channel: UInt64
        let bytes: [UInt8]
        let sentAt: UInt64
        let transmissions: Int
        let firstSentAt: UInt64
        var dummy = false
    }
    private struct Retry {
        let channel: UInt64
        let bytes: [UInt8]
        let transmissions: Int
        let firstSentAt: UInt64
    }

    private let mtu: Int
    private let payloadLimit: Int
    private var sendSequence: UInt64
    private var sendFloor: UInt64
    private var sendChannel: UInt64 = 1
    private var receiveBase: UInt64
    private var receiveHigh: UInt64
    private var receiveChannel: UInt64 = 1
    private var received: Set<UInt64> = []
    private var reordered: [UInt64: [UInt8]] = [:]
    private var reorderBytes = 0
    private var highestReceivedAt: UInt64
    private var pending: [UInt64: Segment] = [:]
    private var pendingBytes = 0
    private var retryBytes = 0
    private var earliestReliableAt: UInt64?
    private var reliabilityDeadlineDirty = false
    private var writes = CircularBuffer<Write>()
    private var retries = CircularBuffer<Retry>()
    private var ackDue: UInt64?
    private var unacknowledgedReceives = 0
    private var maxDelayedAcks = 8
    private var delayedAckNanoseconds: UInt64 = 10_000_000
    private var peerWindow: Int
    private var congestionWindow: Double = 10
    private var slowStartThreshold: Double = 1023
    private var recoveryUntil: UInt64 = 0
    private var rttVariance: Double = 0
    private var rtoNanoseconds: UInt64 = 300_000_000
    private var tokens: Double
    private var tokenUpdatedAt: UInt64
    private var lastReceivedAt: UInt64
    private var lastSentAt: UInt64
    private var lastProbeAt: UInt64
    private var highestAcked: UInt64 = 0
    private var sendDelayInfo = true
    private var targetBitrate: Int = 10_000_000

    private(set) var queuedBytes = 0
    private(set) var retransmissionCount = 0
    private(set) var smoothedRTTNanoseconds: Double = 0
    private(set) var rttMeasuredAt: UInt64 = 0
    private(set) var isClosed = false

    /// These are UDP2 DATA sequences, independent of the MS-RDPEUDP SYN's ISNs.
    /// The receive base comes from the peer's first UDP2 AckOfAcks / DATA header.
    init(initialSendSequence: UInt64 = 100, initialReceiveSequence: UInt64 = 100,
         mtu: Int, peerWindow: Int, now: UInt64) {
        self.mtu = mtu
        // Reserve room for prefix, header, DATA, AOA and DELAYACKINFO; ACKs are separate.
        payloadLimit = mtu - 12
        sendSequence = initialSendSequence
        sendFloor = initialSendSequence
        // A full epoch leaves the preceding sequence representable when the wire base is zero.
        receiveBase = initialReceiveSequence + 0x10000
        receiveHigh = receiveBase - 1
        self.peerWindow = min(max(peerWindow, 1), Self.window)
        highestReceivedAt = now
        tokenUpdatedAt = now
        lastReceivedAt = now
        lastSentAt = now
        lastProbeAt = now
        tokens = Double(10 * mtu)
    }

    var bufferedBytes: Int {
        queuedBytes + pendingBytes + retryBytes
    }

    func setTargetBitrate(_ bitrate: Int) { targetBitrate = max(bitrate, 128_000) }

    func enqueue(_ bytes: ByteBuffer, onSent: Completion?) throws {
        guard !isClosed else { throw RDPUDPError.tunnelClosed }
        guard bufferedBytes + bytes.readableBytes <= Self.maximumBufferedBytes else {
            throw RDPUDPError.bufferOverflow
        }
        guard bytes.readableBytes > 0 else { onSent?(); return }
        queuedBytes += bytes.readableBytes
        writes.append(Write(buffer: bytes, onSent: onSent))
    }

    /// Returns only ordered, nonduplicate reliable-channel bytes, never dummy data.
    func receive(_ wire: [UInt8], now: UInt64) throws -> [[UInt8]] {
        try receive(RDPUDP2Packet.parse(wire), now: now)
    }

    func receive(_ packet: RDPUDP2Packet, now: UInt64) throws -> [[UInt8]] {
        guard !isClosed else { return [] }
        peerWindow = min(1 << packet.logWindow, Self.window)
        lastReceivedAt = now
        if let ack = packet.ack, sendSequence > 0 {
            let sequence = RDPUDP2Packet.expand(ack.sequence, near: sendSequence - 1)
            if sequence < sendSequence {
                acknowledge(through: sequence, delayMs: ack.delayMilliseconds, now: now)
            }
        }
        if let vector = packet.vector, sendSequence > 0 {
            let base = RDPUDP2Packet.expand(vector.base, near: sendSequence - 1)
            let states = vector.states
            if base < sendSequence, states.count <= 32_767 {
                // Vectors may be split or reordered. Only their explicit received
                // states acknowledge data; the prefix can still contain holes.
                let highest = states.lastIndex(of: true).map { base + UInt64($0) }
                for (index, received) in states.enumerated() where received {
                    let sequence = base + UInt64(index)
                    guard sequence < sendSequence else { continue }
                    acknowledge(sequence: sequence,
                                delayMs: sequence == highest ? vector.delayMilliseconds : 255, now: now)
                }
            }
        }
        if let delay = packet.delayAck {
            // The wire field is a byte; bound the local ACK batch per MS-RDPEUDP2 3.1.5.2.
            // mstsc can advertise more than 15. This must not discard its accompanying ACK.
            maxDelayedAcks = min(max(Int(delay.count), 1), 15)
            delayedAckNanoseconds = min(UInt64(delay.milliseconds) * 1_000_000, 100_000_000)
        }
        if let aoa = packet.ackOfAcks {
            let base = RDPUDP2Packet.expand(aoa, near: receiveBase)
            if base > receiveBase, base - receiveBase <= UInt64(Self.window) {
                received = received.filter { $0 >= base }
                receiveBase = base
                advanceReceiveBase()
                if !received.isEmpty { ackDue = now }
            }
        }
        guard let data = packet.data else { detectLoss(now: now); return [] }
        if !packet.dummy, let wireChannel = data.channelSequence {
            guard wireChannel != 0 else { throw RDPUDPError.malformedPacket }
            let channel = RDPUDP2Packet.expand(wireChannel, near: receiveChannel)
            guard channel < receiveChannel || channel - receiveChannel < UInt64(Self.window) else {
                ackDue = now
                return [] // Never ACK reliable bytes that cannot be retained.
            }
        }
        let sequence = RDPUDP2Packet.expand(data.sequence, near: max(receiveHigh, receiveBase))
        guard sequence < receiveBase || sequence - receiveBase < UInt64(Self.window - 1) else {
            // Out-of-window bytes are not ACKed, so the sender can retry after the window advances.
            ackDue = now
            return []
        }
        if sequence >= receiveBase { received.insert(sequence) }
        if sequence > receiveHigh {
            receiveHigh = sequence
            highestReceivedAt = now
        }
        advanceReceiveBase()
        unacknowledgedReceives += 1
        if unacknowledgedReceives >= maxDelayedAcks || !received.isEmpty || sequence < receiveBase - 1 {
            ackDue = now
        } else if ackDue == nil {
            ackDue = now + delayedAckNanoseconds
        }
        var delivered: [[UInt8]] = []
        if !packet.dummy, let wireChannel = data.channelSequence {
            let channel = RDPUDP2Packet.expand(wireChannel, near: receiveChannel)
            if channel >= receiveChannel, channel - receiveChannel < UInt64(Self.window), reordered[channel] == nil {
                guard reorderBytes + data.bytes.count <= Self.window * mtu else {
                    throw RDPUDPError.bufferOverflow
                }
                reordered[channel] = data.bytes
                reorderBytes += data.bytes.count
            }
            while let bytes = reordered.removeValue(forKey: receiveChannel) {
                reorderBytes -= bytes.count
                delivered.append(bytes)
                receiveChannel = Self.nextChannelSequence(after: receiveChannel)
            }
        }
        detectLoss(now: now)
        return delivered
    }

    func transmit(now: UInt64) throws -> [Transmission] {
        guard !isClosed else { return [] }
        if now - lastReceivedAt >= Self.idleNanoseconds {
            isClosed = true
            throw RDPUDPError.timedOut
        }
        if let oldest = oldestReliableSend, now - oldest >= Self.idleNanoseconds {
            isClosed = true
            throw RDPUDPError.timedOut
        }
        detectLoss(now: now)
        var output: [Transmission] = []
        if let due = ackDue, due <= now {
            output += makeAcknowledgements(now: now)
            ackDue = nil
            unacknowledgedReceives = 0
        }
        refillTokens(now: now)
        let window = min(peerWindow - 1, max(2, Int(congestionWindow)))
        // Bound work per callback, as well as the burst on the wire.
        while output.count < 16, pending.count < window,
              !writes.isEmpty || !retries.isEmpty {
            let bytesNeeded = Double(mtu)
            guard tokens >= bytesNeeded else { break }
            let sequence = sendSequence
            let lowest = sendFloor
            guard sequence - lowest < UInt64(min(peerWindow, Self.window) - 1) else { break }
            let channel: UInt64, bytes: [UInt8], count: Int, firstSentAt: UInt64, completion: Completion?
            if let retry = retries.popFirst() {
                channel = retry.channel; bytes = retry.bytes; count = retry.transmissions + 1; completion = nil
                firstSentAt = retry.firstSentAt
                retryBytes -= bytes.count
            } else {
                var write = writes.removeFirst()
                let size = min(payloadLimit, write.buffer.readableBytes)
                bytes = write.buffer.readBytes(length: size)!
                queuedBytes -= size
                channel = sendChannel
                sendChannel = Self.nextChannelSequence(after: sendChannel)
                count = 1
                firstSentAt = now
                completion = write.buffer.readableBytes == 0 ? write.onSent : nil
                if write.buffer.readableBytes > 0 { writes.prepend(write) }
            }
            var packet = RDPUDP2Packet()
            packet.ackOfAcks = UInt16(truncatingIfNeeded: lowest)
            if sendDelayInfo {
                packet.delayAck = .init(count: 8, milliseconds: 10)
                sendDelayInfo = false
            }
            packet.data = .init(sequence: UInt16(truncatingIfNeeded: sequence),
                                channelSequence: UInt16(truncatingIfNeeded: channel), bytes: bytes)
            let wire = packet.encode()
            precondition(wire.count <= mtu)
            pending[sequence] = Segment(channel: channel, bytes: bytes, sentAt: now,
                                        transmissions: count, firstSentAt: firstSentAt)
            pendingBytes += bytes.count
            earliestReliableAt = min(earliestReliableAt ?? firstSentAt, firstSentAt)
            sendSequence += 1
            tokens -= Double(wire.count)
            output.append(Transmission(bytes: wire, onSent: completion))
        }
        let probeDue = now - max(lastProbeAt, rttMeasuredAt) >= Self.keepaliveNanoseconds
        let canProbe = pending.count < window
            && sendSequence - sendFloor < UInt64(max(min(peerWindow, Self.window) - 1, 0))
        if probeDue, canProbe, writes.isEmpty, retries.isEmpty {
            // A transport-only dummy obtains a real RTT sample while the desktop is static.
            // Its loss never triggers retransmission or consumes a reliable channel sequence.
            var probe = try RDPUDP2Packet.parse(makeAcknowledgements(now: now)[0].bytes)
            probe.dummy = true
            probe.data = .init(sequence: UInt16(truncatingIfNeeded: sendSequence), channelSequence: nil, bytes: [])
            pending[sendSequence] = Segment(channel: 0, bytes: [], sentAt: now,
                                            transmissions: 1, firstSentAt: now, dummy: true)
            sendSequence += 1
            lastProbeAt = now
            output.append(Transmission(bytes: probe.encode()))
        } else if output.isEmpty, now - lastSentAt >= Self.keepaliveNanoseconds {
            output = makeAcknowledgements(now: now)
        }
        if !output.isEmpty { lastSentAt = now }
        return output
    }

    func nextDeadline(now: UInt64) -> UInt64? {
        guard !isClosed else { return nil }
        var deadline = min(lastReceivedAt + Self.idleNanoseconds, lastSentAt + Self.keepaliveNanoseconds)
        if let ackDue { deadline = min(deadline, ackDue) }
        if let oldest = pending[sendFloor] {
            deadline = min(deadline, oldest.sentAt + rtoNanoseconds)
            if highestAcked >= sendFloor + 3 {
                let reorderTime = UInt64(max(smoothedRTTNanoseconds * 1.125, 10_000_000))
                deadline = min(deadline, oldest.sentAt + reorderTime)
            }
        }
        if let first = oldestReliableSend { deadline = min(deadline, first + Self.idleNanoseconds) }
        let capacity = min(peerWindow - 1, max(2, Int(congestionWindow)))
        let lowest = sendFloor
        if pending.count < capacity, writes.isEmpty, retries.isEmpty,
           sendSequence - lowest < UInt64(max(min(peerWindow, Self.window) - 1, 0)) {
            deadline = min(deadline, max(lastProbeAt, rttMeasuredAt) + Self.keepaliveNanoseconds)
        }
        if (!writes.isEmpty || !retries.isEmpty), pending.count < capacity,
           sendSequence - lowest < UInt64(max(peerWindow - 1, 0)) {
            let missing = max(Double(mtu) - tokens, 0)
            let delay = UInt64((missing / pacingBytesPerSecond * 1_000_000_000).rounded(.up))
            deadline = min(deadline, now + max(delay, 1_000_000))
        }
        return max(deadline, now)
    }

    private var pacingBytesPerSecond: Double {
        let rtt = max(smoothedRTTNanoseconds, 10_000_000)
        let congestionRate = congestionWindow * Double(mtu) * 1_000_000_000 / rtt
        return min(Double(targetBitrate) / 8, congestionRate * 1.25)
    }

    private var oldestReliableSend: UInt64? {
        if reliabilityDeadlineDirty {
            let pendingTime = pending.values.filter { !$0.dummy }.map(\.firstSentAt).min()
            let retryTime = retries.map(\.firstSentAt).min()
            earliestReliableAt = [pendingTime, retryTime].compactMap { $0 }.min()
            reliabilityDeadlineDirty = false
        }
        return earliestReliableAt
    }

    private func refillTokens(now: UInt64) {
        let seconds = Double(now - tokenUpdatedAt) / 1_000_000_000
        tokens = min(tokens + seconds * pacingBytesPerSecond, Double(10 * mtu))
        tokenUpdatedAt = now
    }

    private func acknowledge(through sequence: UInt64, delayMs: UInt8, now: UInt64) {
        guard sequence >= sendFloor else { return }
        for key in sendFloor...min(sequence, sendSequence - 1) {
            acknowledge(sequence: key, delayMs: key == sequence ? delayMs : 255, now: now)
        }
    }

    private func acknowledge(sequence: UInt64, delayMs: UInt8, now: UInt64) {
        guard let segment = pending.removeValue(forKey: sequence) else { return }
        pendingBytes -= segment.bytes.count
        if segment.firstSentAt == earliestReliableAt { reliabilityDeadlineDirty = true }
        advanceSendFloor()
        highestAcked = max(highestAcked, sequence)
        // Karn's rule: retransmissions and invalid ACK delay must not contaminate RTT.
        if segment.transmissions == 1, delayMs != 255,
           now > segment.sentAt + UInt64(delayMs) * 1_000_000 {
            let sample = Double(now - segment.sentAt - UInt64(delayMs) * 1_000_000)
            if smoothedRTTNanoseconds == 0 {
                smoothedRTTNanoseconds = sample
                rttVariance = sample / 2
            } else {
                rttVariance = 0.75 * rttVariance + 0.25 * abs(smoothedRTTNanoseconds - sample)
                smoothedRTTNanoseconds = 0.875 * smoothedRTTNanoseconds + 0.125 * sample
            }
            rtoNanoseconds = UInt64(min(max(smoothedRTTNanoseconds + 4 * rttVariance, 100_000_000), 3_000_000_000))
            rttMeasuredAt = now
        }
        if !segment.dummy, sequence >= recoveryUntil {
            congestionWindow += congestionWindow < slowStartThreshold ? 1 : 1 / congestionWindow
            congestionWindow = min(congestionWindow, Double(Self.window - 1))
        }
    }

    private func detectLoss(now: UInt64) {
        guard let oldest = pending[sendFloor] else { return }
        let reorderTime = UInt64(max(smoothedRTTNanoseconds * 1.125, 10_000_000))
        guard now - oldest.sentAt >= rtoNanoseconds
                || (highestAcked >= sendFloor + 3 && now - oldest.sentAt >= reorderTime) else { return }
        let lost = pending.filter { sequence, segment in
            now - segment.sentAt >= rtoNanoseconds
                || (highestAcked >= sequence + 3 && now - segment.sentAt >= reorderTime)
        }.keys.max()
        guard let lost else { return }
        let timedOut = pending[lost].map { now - $0.sentAt >= rtoNanoseconds } ?? false
        let reliableLoss = pending.contains { sequence, segment in sequence <= lost && !segment.dummy }
        if reliableLoss, lost >= recoveryUntil {
            slowStartThreshold = max(congestionWindow / 2, 2)
            congestionWindow = slowStartThreshold
            recoveryUntil = sendSequence
        }
        if reliableLoss, timedOut {
            congestionWindow = 2
            rtoNanoseconds = min(rtoNanoseconds * 2, 3_000_000_000)
        }
        for sequence in pending.keys.filter({ $0 <= lost }).sorted() {
            guard let segment = pending.removeValue(forKey: sequence) else { continue }
            pendingBytes -= segment.bytes.count
            if segment.dummy { continue }
            retryBytes += segment.bytes.count
            retries.append(Retry(channel: segment.channel, bytes: segment.bytes,
                                 transmissions: segment.transmissions, firstSentAt: segment.firstSentAt))
            retransmissionCount += 1
        }
        advanceSendFloor()
        // The receiver must learn that the abandoned transport sequences will not arrive.
        ackDue = min(ackDue ?? now, now)
    }

    private func advanceReceiveBase() {
        while received.remove(receiveBase) != nil { receiveBase += 1 }
    }

    /// MS-RDPEUDP2 3.1.1.2.4.2 product behavior: Windows always skips wire channel zero.
    /// Transport DATA sequences still wrap through zero normally.
    private static func nextChannelSequence(after sequence: UInt64) -> UInt64 {
        let next = sequence + 1
        return next & 0xFFFF == 0 ? next + 1 : next
    }

    private func advanceSendFloor() {
        while sendFloor < sendSequence, pending[sendFloor] == nil { sendFloor += 1 }
    }

    private func makeAcknowledgements(now: UInt64) -> [Transmission] {
        let gap = UInt8(min((now - highestReceivedAt) / 1_000_000, 254))
        let timestamp = UInt32(truncatingIfNeeded: highestReceivedAt / 4_000) & 0xFFFFFF
        let aoa = UInt16(truncatingIfNeeded: sendFloor)
        if received.isEmpty {
            var packet = RDPUDP2Packet()
            packet.ack = .init(sequence: UInt16(truncatingIfNeeded: receiveBase - 1),
                               timestamp: timestamp, delayMilliseconds: gap)
            packet.ackOfAcks = aoa
            return [Transmission(bytes: packet.encode())]
        }
        var output: [Transmission] = []
        var base = receiveBase
        while base <= receiveHigh {
            let first = base
            var coded: [UInt8] = []
            while base <= receiveHigh, coded.count < 127 {
                let state = received.contains(base)
                var run = 1
                while run < 63, base + UInt64(run) <= receiveHigh,
                      received.contains(base + UInt64(run)) == state { run += 1 }
                if run >= 7 || receiveHigh - base < 6 {
                    coded.append(0x80 | (state ? 0x40 : 0) | UInt8(run))
                    base += UInt64(run)
                } else {
                    var map: UInt8 = 0
                    for bit in 0..<7 where received.contains(base + UInt64(bit)) { map |= 1 << bit }
                    coded.append(map)
                    base += 7
                }
            }
            var packet = RDPUDP2Packet()
            packet.vector = .init(base: UInt16(truncatingIfNeeded: first),
                                  timestamp: base > receiveHigh ? timestamp : nil,
                                  delayMilliseconds: gap, coded: coded)
            packet.ackOfAcks = aoa
            output.append(Transmission(bytes: packet.encode()))
        }
        return output
    }
}
