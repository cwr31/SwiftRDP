import XCTest
import os
@testable import SwiftRDPCore

final class DynamicVCWriteTests: XCTestCase {
    func testManagerRejectsDataWithoutABatchWriter() {
        let manager = DynamicVCManager()
        var writes = 0
        manager.send = { _ in writes += 1 }
        let completed = OSAllocatedUnfairLock<Bool>(initialState: false)

        XCTAssertNil(manager.sendDataBatch(channelId: 1, payloads: [[1]], priority: .video) { _ in
            completed.withLock { $0 = true }
        })
        XCTAssertEqual(writes, 0)
        XCTAssertFalse(completed.withLock { $0 })
    }

    func testDrdynvcRejectsDataWithoutABatchWriter() {
        let channel = DrdynvcChannel()
        var writes = 0
        channel.send = { _ in writes += 1 }
        channel.onOpen(channelId: 1004)
        let completed = OSAllocatedUnfairLock<Bool>(initialState: false)

        XCTAssertNil(channel.manager.sendDataBatch(channelId: 1, payloads: [[1]], priority: .video) { _ in
            completed.withLock { $0 = true }
        })
        XCTAssertEqual(writes, 0)
        XCTAssertFalse(completed.withLock { $0 })
    }

    func testRouterRejectsDataWithoutABatchWriter() {
        let router = VirtualChannelRouter()
        router.bind(channelId: 1004, name: "drdynvc")
        let completed = OSAllocatedUnfairLock<Bool>(initialState: false)

        XCTAssertNil(router.dynamicVC.sendDataBatch(channelId: 1, payloads: [[1]], priority: .video) { _ in
            completed.withLock { $0 = true }
        })
        XCTAssertFalse(completed.withLock { $0 })
    }

    func testRouterPreservesPriorityAndWriterCompletionThroughEveryLayer() {
        let router = VirtualChannelRouter()
        let completed = OSAllocatedUnfairLock<UInt64?>(initialState: nil)
        var pendingCompletion: RDPSocket.WriteCompletion?
        router.sendToChannelBatch = { channelID, packets, priority, onWritten in
            XCTAssertEqual(channelID, 1004)
            XCTAssertEqual(priority, .video)
            XCTAssertEqual(packets.count, 2)
            pendingCompletion = onWritten
            return packets.reduce(0) { $0 + $1.count }
        }
        router.bind(channelId: 1004, name: "drdynvc")

        XCTAssertNotNil(router.dynamicVC.sendDataBatch(channelId: 1, payloads: [[1], [2]], priority: .video) { timestamp in
            completed.withLock { $0 = timestamp }
        })
        XCTAssertNil(completed.withLock { $0 })
        XCTAssertNotNil(pendingCompletion)
        pendingCompletion?(123)
        XCTAssertEqual(completed.withLock { $0 }, 123)
    }

    func testMissingUDPSenderDoesNotSilentlySendGraphicsOnTCP() {
        let manager = DynamicVCManager()
        manager.send = { _ in }
        manager.sendServerCapsIfNeeded()
        manager.handle(pdu: [0x50, 0, 3, 0])
        manager.createChannel(name: DynamicVCManager.graphicsDVCName)
        manager.handle(pdu: [0x10, 1, 0, 0, 0, 0])

        var tcpBatches = 0
        manager.sendBatch = { packets, _, _ in
            tcpBatches += 1
            return packets.reduce(0) { $0 + $1.count }
        }
        manager.sendMultitransportBatch = { packets, _, _ in
            packets.reduce(0) { $0 + $1.count }
        }
        XCTAssertTrue(manager.switchToMultitransport(channelId: 1) { _ in })
        XCTAssertEqual(tcpBatches, 1)

        manager.sendMultitransportBatch = nil
        let completed = OSAllocatedUnfairLock<Bool>(initialState: false)
        XCTAssertNil(manager.sendDataBatch(channelId: 1, payloads: [[1]], priority: .video) { _ in
            completed.withLock { $0 = true }
        })
        XCTAssertEqual(tcpBatches, 1)
        XCTAssertFalse(completed.withLock { $0 })
    }
}
