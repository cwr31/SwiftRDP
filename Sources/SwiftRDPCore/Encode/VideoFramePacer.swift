import Foundation

/// Keep cadence on its scheduled clock so small timer delays do not accumulate.
/// Long stalls start a fresh deadline instead of replaying missed frames.
struct VideoFramePacer {
    private var lastSubmissionNanoseconds: UInt64?
    private var intervalNanoseconds: UInt64?
    private var nextDeadlineNanoseconds: UInt64?

    mutating func remainingWaitNanoseconds(fps: Int, now: UInt64) -> UInt64 {
        let interval = 1_000_000_000 / UInt64(max(fps, 1))
        if intervalNanoseconds != interval {
            intervalNanoseconds = interval
            nextDeadlineNanoseconds = lastSubmissionNanoseconds.map { $0 &+ interval }
        }
        guard let deadline = nextDeadlineNanoseconds, deadline > now else { return 0 }
        return deadline - now
    }

    mutating func noteSubmission(at now: UInt64) {
        if let interval = intervalNanoseconds {
            if let deadline = nextDeadlineNanoseconds, now >= deadline, now - deadline < interval {
                nextDeadlineNanoseconds = deadline &+ interval
            } else {
                nextDeadlineNanoseconds = now &+ interval
            }
        }
        lastSubmissionNanoseconds = now
    }
}
