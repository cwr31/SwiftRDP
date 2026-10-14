/// Capture admission and bounded static refresh, owned by the GFX state lock.
struct AVCFrameScheduler {
    static let quietIntervalNanoseconds: UInt64 = 250_000_000
    static let refinementIntervalNanoseconds: UInt64 = 200_000_000
    static let maxRefinementAttempts = 1

    static func refinementByteLimit(bitrate: Int) -> Int {
        // Leave 10% of a 200 ms pacing budget for RDP/transport framing.
        max(bitrate / 8 / 5 * 9 / 10, 1)
    }

    struct Submission: Sendable {
        let sequence: UInt64
        let isRefinement: Bool
    }

    private var latestSequence: UInt64 = 0
    private var deliveredSequence: UInt64 = 0
    private var deliveredError: Double?
    private var pendingSequences = Set<UInt64>()
    private var quietUntil: UInt64 = 0
    private var refineAt: UInt64 = 0
    private var retryAt: UInt64 = 0
    private var refinementAttempts = 0
    private var bitrate = 0
    private var refinementAllowed = true

    mutating func observe(sequence: UInt64, now: UInt64) {
        guard sequence > latestSequence else { return }
        latestSequence = sequence
        quietUntil = now + Self.quietIntervalNanoseconds
        requestRefinement(now: now)
    }

    mutating func updateBudget(bitrate: Int, refinementAllowed: Bool, now: UInt64) {
        if self.bitrate > 0 && bitrate > self.bitrate {
            requestRefinement(now: now)
        }
        self.bitrate = bitrate
        self.refinementAllowed = refinementAllowed
    }

    mutating func requestRefinement(now: UInt64) {
        refinementAttempts = Self.maxRefinementAttempts
        refineAt = max(refineAt, quietUntil, now)
    }

    mutating func reserve(sequence: UInt64, forced: Bool, now: UInt64) -> Submission? {
        guard sequence > 0, sequence == latestSequence,
              !pendingSequences.contains(sequence), now >= retryAt else { return nil }
        let isRefinement = !forced && sequence <= deliveredSequence
        if isRefinement {
            guard refinementAllowed, pendingSequences.isEmpty,
                  let deliveredError, deliveredError > 0,
                  refinementAttempts > 0, now >= refineAt else { return nil }
            // Count attempts, not successes: failed optional refreshes must not
            // turn an idle desktop into an unlimited encode retry loop.
            refinementAttempts -= 1
            refineAt = now + Self.refinementIntervalNanoseconds
        }
        pendingSequences.insert(sequence)
        return Submission(sequence: sequence, isRefinement: isRefinement)
    }

    mutating func complete(
        _ submission: Submission,
        sent: Bool,
        now: UInt64,
        meanSquaredError: Double? = nil,
        retryAfterNanoseconds: UInt64 = 0
    ) {
        guard pendingSequences.remove(submission.sequence) != nil else { return }
        if sent, submission.sequence >= deliveredSequence {
            deliveredSequence = submission.sequence
            deliveredError = meanSquaredError
        } else if retryAfterNanoseconds > 0 {
            retryAt = max(retryAt, now + retryAfterNanoseconds)
        }
    }

    func shouldSendRefinement(_ submission: Submission, meanSquaredError: Double?,
                              bytes: Int, byteLimit: Int) -> Bool {
        guard submission.isRefinement, submission.sequence == latestSequence, bytes <= byteLimit,
              let deliveredError, let meanSquaredError, meanSquaredError.isFinite,
              meanSquaredError >= 0 else { return false }
        return meanSquaredError < deliveredError * 0.9
    }

    func nextWaitNanoseconds(now: UInt64) -> UInt64? {
        guard latestSequence > 0, !pendingSequences.contains(latestSequence) else { return nil }
        let deadline: UInt64
        if latestSequence > deliveredSequence {
            deadline = retryAt
        } else {
            guard refinementAllowed, pendingSequences.isEmpty,
                  let deliveredError, deliveredError > 0,
                  refinementAttempts > 0 else { return nil }
            deadline = max(refineAt, retryAt)
        }
        return deadline > now ? deadline - now : 0
    }
}
