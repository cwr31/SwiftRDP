import XCTest
import os
@testable import SwiftRDPCore

final class SocketWriteTests: XCTestCase {
    func testMissingWriterDoesNotReportSuccessfulWriteOrCompletion() {
        let socket = RDPSocket()
        let completed = OSAllocatedUnfairLock<Bool>(initialState: false)
        XCTAssertFalse(socket.write([1]))
        XCTAssertFalse(socket.writeBatch([[1], [2]], priority: .video) { _ in
            completed.withLock { $0 = true }
        })
        XCTAssertFalse(completed.withLock { $0 })
    }

    func testBatchPreservesPriorityAndWaitsForWriterCompletion() {
        let socket = RDPSocket()
        let completed = OSAllocatedUnfairLock<UInt64?>(initialState: nil)
        var pendingCompletion: RDPSocket.WriteCompletion?
        socket.onWriteBatch = { packets, priority, onWritten in
            XCTAssertEqual(packets, [[1], [2]])
            XCTAssertEqual(priority, .video)
            pendingCompletion = onWritten
            return true
        }
        XCTAssertTrue(socket.writeBatch([[1], [2]], priority: .video) { timestamp in
            completed.withLock { $0 = timestamp }
        })
        XCTAssertNil(completed.withLock { $0 })
        XCTAssertNotNil(pendingCompletion)
        pendingCompletion?(123)
        XCTAssertEqual(completed.withLock { $0 }, 123)
    }

    func testRejectedBatchDoesNotReportCompletion() {
        let socket = RDPSocket()
        let completed = OSAllocatedUnfairLock<Bool>(initialState: false)
        socket.onWriteBatch = { _, _, _ in false }
        XCTAssertFalse(socket.writeBatch([[1]], priority: .video) { _ in
            completed.withLock { $0 = true }
        })
        XCTAssertFalse(completed.withLock { $0 })
    }
}
