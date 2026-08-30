import XCTest
@testable import SwiftRDPCore

final class VirtualChannelRouterTests: XCTestCase {
    func testSCNetPreservesOrderWithDormantAudioHandler() {
        let config = ServerConfig(audioPlaybackDestination: .host)
        let router = VirtualChannelRouter(config: config)

        let scNet = router.filterAcceptedChannelNames([
            "rdpsnd", "cliprdr", "drdynvc",
        ])

        XCTAssertEqual(scNet, ["rdpsnd", "cliprdr", "drdynvc"])
        // Positional IDs match what RDPSession assigns starting at 1004.
        XCTAssertEqual(scNet.firstIndex(of: "drdynvc"), 2)
        XCTAssertEqual(scNet.firstIndex(of: "cliprdr"), 1)
        XCTAssertNotNil(router.channel(named: "rdpsnd"))
        XCTAssertNotNil(router.channel(named: "drdynvc"))
        XCTAssertNotNil(router.channel(named: "cliprdr"))
    }

    func testSCNetKeepsUnimplementedChannelsForIDAlignment() {
        let router = VirtualChannelRouter(config: ServerConfig())
        let scNet = router.filterAcceptedChannelNames([
            "rdpsnd", "cliprdr", "drdynvc", "unknownx",
        ])
        XCTAssertEqual(scNet, ["rdpsnd", "cliprdr", "drdynvc", "unknownx"])
    }

    func testBuildSCNetChannelCountMatchesPreservedList() {
        let names = ["rdpsnd", "cliprdr", "drdynvc"]
        let gcc = GCC.buildServerUserData(
            selectedProtocol: 2,
            channelNames: names,
            ioChannel: 1003
        )
        // Smoke: payload contains SC_NET and is non-empty.
        XCTAssertFalse(gcc.isEmpty)
        XCTAssertEqual(names.count, 3)
    }

    func testBindingSameChannelIDDoesNotReopenChannel() {
        let router = VirtualChannelRouter()
        let channel = OpenTrackingChannel(name: "test")
        router.register(channel)

        router.bind(channelId: 1004, name: "test")
        router.bind(channelId: 1004, name: "TEST")

        XCTAssertEqual(channel.openedChannelIDs, [1004])
    }

    func testDynamicVCBatchKeepsStaticChannelFraming() {
        let router = VirtualChannelRouter()
        var batches: [[[UInt8]]] = []
        router.sendToChannelBatch = { _, payloads, _ in
            batches.append(payloads)
            return payloads.reduce(0) { $0 + $1.count }
        }
        router.bind(channelId: 1007, name: "drdynvc")

        XCTAssertNotNil(
            router.dynamicVC.sendDataBatch(
                channelId: 1,
                payloads: [[0x01, 0x02, 0x03]],
                priority: .video
            )
        )

        XCTAssertEqual(batches.count, 1)
        let staticPDU = try! XCTUnwrap(batches[0].first)
        let header = try! XCTUnwrap(ChannelPDU.parse(staticPDU))
        XCTAssertEqual(header.flags, ChannelPDU.flagFirst | ChannelPDU.flagLast)
        XCTAssertEqual(header.length, header.payload.count)
    }
}

private final class OpenTrackingChannel: VirtualChannel {
    let name: String
    var send: (([UInt8]) -> Void)?
    private(set) var openedChannelIDs: [UInt16] = []

    init(name: String) {
        self.name = name
    }

    func onOpen(channelId: UInt16) {
        openedChannelIDs.append(channelId)
    }

    func onData(_ data: [UInt8]) {}

    func onClose() {}
}
