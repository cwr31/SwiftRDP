import Foundation

struct FrameAckSample: Equatable {
    let latencyMs: Double
    let unacked: Int
    let acknowledgedBytes: Int
    let acknowledgementIntervalMs: Double
}

/// Tracks GFX frame send times so FRAME_ACK latency is measured from the
/// acknowledged frame, rather than from the previous ACK arrival.
final class FrameAckTracker {
    private static let serialNumberHalfRange: UInt32 = 0x8000_0000
    private let lock = NSLock()
    private struct Entry {
        let enqueuedAtNanoseconds: UInt64
        var sentAtNanoseconds: UInt64
        var bytes: Int
    }

    private var entries: [UInt32: Entry] = [:]
    private var lastAcknowledgementNanoseconds: UInt64?

    static func isSerialNumberAtOrBefore(_ value: UInt32, _ boundary: UInt32) -> Bool {
        boundary &- value < serialNumberHalfRange
    }

    static func isSerialNumberAtOrAfter(_ value: UInt32, _ boundary: UInt32) -> Bool {
        value &- boundary < serialNumberHalfRange
    }

    private static func serialDistance(from boundary: UInt32, to value: UInt32) -> UInt32 {
        boundary &- value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func track(
        frameId: UInt32,
        bytes: Int = 0,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        lock.lock()
        entries[frameId] = Entry(
            enqueuedAtNanoseconds: nowNanoseconds,
            sentAtNanoseconds: nowNanoseconds,
            bytes: max(bytes, 0)
        )
        lock.unlock()
    }

    func remove(frameId: UInt32) {
        lock.lock()
        entries.removeValue(forKey: frameId)
        lock.unlock()
    }

    @discardableResult
    func noteFrameWritten(frameId: UInt32, nowNanoseconds: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard entries[frameId] != nil else { return false }
        entries[frameId]?.sentAtNanoseconds = nowNanoseconds
        return true
    }

    func updateBytes(frameId: UInt32, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        entries[frameId]?.bytes = max(bytes, 0)
    }

    func acknowledge(
        upTo frameId: UInt32,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> FrameAckSample? {
        lock.lock()
        defer { lock.unlock() }

        let acknowledgedIds = entries.keys.filter {
            Self.isSerialNumberAtOrBefore($0, frameId)
        }
        guard let measuredId = acknowledgedIds.min(by: {
            Self.serialDistance(from: frameId, to: $0)
                < Self.serialDistance(from: frameId, to: $1)
        }),
              let measured = entries[measuredId] else {
            return nil
        }
        let acknowledgedBytes = acknowledgedIds.reduce(0) { $0 + (entries[$1]?.bytes ?? 0) }
        let firstSend = acknowledgedIds.compactMap { entries[$0]?.enqueuedAtNanoseconds }.min()
            ?? measured.enqueuedAtNanoseconds
        let intervalStart = max(lastAcknowledgementNanoseconds ?? firstSend, firstSend)
        for id in acknowledgedIds {
            entries.removeValue(forKey: id)
        }
        lastAcknowledgementNanoseconds = nowNanoseconds
        let elapsed = nowNanoseconds >= measured.sentAtNanoseconds
            ? nowNanoseconds - measured.sentAtNanoseconds
            : 0
        let acknowledgementInterval = nowNanoseconds >= intervalStart
            ? nowNanoseconds - intervalStart
            : 0
        return FrameAckSample(
            latencyMs: Double(elapsed) / 1_000_000,
            unacked: entries.count,
            acknowledgedBytes: acknowledgedBytes,
            acknowledgementIntervalMs: Double(acknowledgementInterval) / 1_000_000
        )
    }

    @discardableResult
    func reset() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let count = entries.count
        entries.removeAll(keepingCapacity: true)
        lastAcknowledgementNanoseconds = nil
        return count
    }
}
