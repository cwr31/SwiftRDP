import XCTest
@testable import SwiftRDPCore

final class OrderedFrameOutputTests: XCTestCase {
    func testOutOfOrderCompletionRetainsCapacityUntilEarlierFrameFinishes() {
        var queue = OrderedFrameOutput<String>(capacity: 2)
        XCTAssertTrue(queue.reserve(1))
        XCTAssertTrue(queue.reserve(2))
        XCTAssertEqual(queue.complete(2, with: "second"), [])
        XCTAssertFalse(queue.reserve(3))
        XCTAssertEqual(queue.complete(1, with: "first"), ["first", "second"])
        XCTAssertTrue(queue.reserve(3))
        XCTAssertEqual(queue.complete(3, with: "third"), ["third"])
    }

    func testFailureReleasesLaterResultsInSubmissionOrder() {
        var queue = OrderedFrameOutput<Result<Int, TestFailure>>(capacity: 2)
        XCTAssertTrue(queue.reserve(1))
        XCTAssertTrue(queue.reserve(2))
        XCTAssertTrue(queue.complete(2, with: .success(2)).isEmpty)
        let results = queue.complete(1, with: .failure(.timeout))
        XCTAssertEqual(results.count, 2)
        guard case .failure(.timeout) = results[0], case .success(2) = results[1] else {
            return XCTFail("failure must precede the dependent output")
        }
    }

    func testResetDiscardsOldOutputsAndDuplicateCompletion() {
        var queue = OrderedFrameOutput<Int>(capacity: 2)
        XCTAssertTrue(queue.reserve(1))
        XCTAssertFalse(queue.reserve(1))
        queue.reset()
        XCTAssertEqual(queue.complete(1, with: 1), [])
        XCTAssertTrue(queue.reserve(2))
        XCTAssertEqual(queue.complete(2, with: 2), [2])
        XCTAssertEqual(queue.complete(2, with: 2), [])
    }

    private enum TestFailure: Error { case timeout }
}
