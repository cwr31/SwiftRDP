import Foundation

/// Producer and ACK wakeups may resume work, but cannot advance a frame deadline.
struct VideoFramePacer {
    private var lastSubmissionNanoseconds: UInt64?

    func remainingWaitNanoseconds(fps: Int, now: UInt64) -> UInt64 {
        guard let lastSubmissionNanoseconds, now >= lastSubmissionNanoseconds else { return 0 }
        let interval = 1_000_000_000 / UInt64(max(fps, 1))
        let elapsed = now - lastSubmissionNanoseconds
        return elapsed < interval ? interval - elapsed : 0
    }

    mutating func noteSubmission(at now: UInt64) {
        lastSubmissionNanoseconds = now
    }
}
