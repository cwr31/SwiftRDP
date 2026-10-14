import Foundation
import XCTest
@testable import SwiftRDPCore

final class RDPPulseSignalTests: XCTestCase {
    func testAFramePublishedBeforeWaitCannotLoseItsWakeup() async {
        let signal = RDPPulseSignal()
        signal.signal()
        let start = ContinuousClock.now
        await signal.wait(timeoutNanoseconds: 2_000_000_000)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
    }

    func testRepeatedSignalsCoalesceInsteadOfSpinningTheDesktopLoop() async {
        let signal = RDPPulseSignal()
        for _ in 0..<100 { signal.signal() }
        await signal.wait(timeoutNanoseconds: 2_000_000_000)
        let start = ContinuousClock.now
        await signal.wait(timeoutNanoseconds: 40_000_000)
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(30))
    }

    func testCancelledWaitDoesNotConsumeTheNextFrameNotification() async {
        let signal = RDPPulseSignal()
        let waiter = Task { await signal.wait(timeoutNanoseconds: 2_000_000_000) }
        waiter.cancel()
        await waiter.value
        signal.signal()
        let start = ContinuousClock.now
        await signal.wait(timeoutNanoseconds: 2_000_000_000)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
    }
}
