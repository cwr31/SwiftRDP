import XCTest
@testable import SwiftRDPCore

final class DisplayControlChannelTests: XCTestCase {
    func testCapsAdvertiseTheImplementedSingleMonitorGeometry() {
        let channel = DisplayControlChannel()
        var caps: [UInt8] = []
        channel.attach { caps = $0 }
        XCTAssertEqual(caps, ByteWriter.u32(5) + ByteWriter.u32(20)
            + ByteWriter.u32(1) + ByteWriter.u32(8192) + ByteWriter.u32(8192))
    }

    func testValidLayoutResizesAndCoalescesImmediateDuplicates() {
        let channel = DisplayControlChannel()
        var sizes: [[Int]] = []
        channel.onResize = { sizes.append([$0, $1]) }
        channel.handle(layout())
        channel.handle(layout())
        channel.handle(layout(width: 1920, height: 1080))
        XCTAssertEqual(sizes, [[1024, 768], [1920, 1080]])
        channel.attach { _ in }
        channel.handle(layout(width: 1920, height: 1080))
        XCTAssertEqual(sizes.count, 3)
    }

    func testMalformedLayoutsDoNotMutateResizeState() {
        let channel = DisplayControlChannel()
        var resizes = 0
        channel.onResize = { _, _ in resizes += 1 }
        let valid = layout()
        for count in 0..<valid.count { channel.handle(Array(valid.prefix(count))) }
        channel.handle(valid + [0])
        for offset in [0, 4, 8, 12, 16, 20, 24] {
            var invalid = valid
            invalid[offset] ^= 1
            channel.handle(invalid)
        }
        for width in [0, 199, 201, 8194, UInt32.max] { channel.handle(layout(width: width)) }
        for height in [0, 199, 8193, UInt32.max] { channel.handle(layout(height: height)) }
        XCTAssertEqual(resizes, 0)
        channel.handle(valid)
        XCTAssertEqual(resizes, 1)
    }

    func testResizeAndTouchDVCsAreOpenedAfterCapsWithoutGFX() {
        let session = RDPSession(config: ServerConfig(displayMode: .bitmap))
        var writes: [[UInt8]] = []
        session.dvc.send = { writes.append($0) }
        session.dvc.sendBatch = { packets, priority, _ in
            XCTAssertEqual(priority, .control)
            writes.append(contentsOf: packets)
            return packets.reduce(0) { $0 + $1.count }
        }
        session.registerStandardDVCs()
        XCTAssertTrue(writes.isEmpty)
        session.dvc.handle(pdu: [0x50, 0, 3, 0])
        let names = writes.filter { $0.first == 0x10 }.map {
            String(bytes: $0.dropFirst(2).dropLast(), encoding: .utf8)
        }
        XCTAssertEqual(names, [DisplayControlChannel.dvcName, TouchInput.dvcName])
        session.dvc.handle(pdu: [0x10, 1] + ByteWriter.u32(0))
        XCTAssertEqual(session.dvc.channelId(forName: DisplayControlChannel.dvcName), 1)
        let displayCaps = writes.last
        XCTAssertEqual(displayCaps?.first, 0x30)
        XCTAssertEqual(displayCaps?.dropFirst(2).count, 20)
    }

    private func layout(width: UInt32 = 1024, height: UInt32 = 768) -> [UInt8] {
        let fields: [UInt32] = [2, 56, 40, 1, 1, 0, 0, width, height, 320, 240, 0, 100, 100]
        return fields.flatMap { ByteWriter.u32($0) }
    }
}
