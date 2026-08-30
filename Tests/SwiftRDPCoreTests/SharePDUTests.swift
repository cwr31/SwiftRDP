import XCTest
@testable import SwiftRDPCore

final class SharePDUTests: XCTestCase {
    func testParsesSurfaceAndFrameAcknowledgeCapabilitiesFromConfirmActive() {
        let pdu = confirmActive(
            surfaceCommandFlags: 0x0000_0052,
            maxUnacknowledgedFrameCount: 3
        )

        let capabilities = SharePDU.parseConfirmActiveCapabilities(pdu)

        XCTAssertEqual(capabilities.surfaceCommandFlags, 0x0000_0052)
        XCTAssertTrue(capabilities.hasSurfaceCommands)
        XCTAssertEqual(capabilities.maxUnacknowledgedFrameCount, 3)
        XCTAssertTrue(SharePDU.confirmActiveHasSurfaceCommands(pdu))
    }

    func testMissingFrameAcknowledgeCapabilityRemainsDistinguishableFromZero() {
        let absent = SharePDU.parseConfirmActiveCapabilities(
            confirmActive(surfaceCommandFlags: 0x10, maxUnacknowledgedFrameCount: nil)
        )
        let zero = SharePDU.parseConfirmActiveCapabilities(
            confirmActive(surfaceCommandFlags: 0x10, maxUnacknowledgedFrameCount: 0)
        )

        XCTAssertNil(absent.maxUnacknowledgedFrameCount)
        XCTAssertEqual(zero.maxUnacknowledgedFrameCount, 0)
    }

    func testLargePointerRequiresMatchingMultifragmentCapability() {
        let supported = SharePDU.parseConfirmActiveCapabilities(confirmActive(
            surfaceCommandFlags: nil,
            maxUnacknowledgedFrameCount: nil,
            largePointerSupportFlags: 0x0001,
            multifragmentMaxRequestSize: 38_055
        ))
        let missingMultifragment = SharePDU.parseConfirmActiveCapabilities(confirmActive(
            surfaceCommandFlags: nil,
            maxUnacknowledgedFrameCount: nil,
            largePointerSupportFlags: 0x0001
        ))
        let tooSmall = SharePDU.parseConfirmActiveCapabilities(confirmActive(
            surfaceCommandFlags: nil,
            maxUnacknowledgedFrameCount: nil,
            largePointerSupportFlags: 0x0001,
            multifragmentMaxRequestSize: 38_054
        ))

        XCTAssertEqual(supported.maximumPointerDimension, 96)
        XCTAssertEqual(missingMultifragment.maximumPointerDimension, 32)
        XCTAssertEqual(tooSmall.maximumPointerDimension, 32)
    }

    private func confirmActive(
        surfaceCommandFlags: UInt32?,
        maxUnacknowledgedFrameCount: UInt32?,
        largePointerSupportFlags: UInt16? = nil,
        multifragmentMaxRequestSize: UInt32? = nil
    ) -> [UInt8] {
        var capabilitySets: [UInt8] = []
        var capabilityCount: UInt16 = 0
        if let surfaceCommandFlags {
            capabilitySets.append(contentsOf: capabilitySet(
                type: SharePDU.capsetSurfaceCommands,
                value: surfaceCommandFlags
            ))
            capabilityCount += 1
        }
        if let maxUnacknowledgedFrameCount {
            capabilitySets.append(contentsOf: capabilitySet(
                type: SharePDU.capsetFrameAck,
                value: maxUnacknowledgedFrameCount
            ))
            capabilityCount += 1
        }
        if let largePointerSupportFlags {
            capabilitySets.append(contentsOf: capabilitySet(
                type: SharePDU.capsetLargePointer,
                value: largePointerSupportFlags
            ))
            capabilityCount += 1
        }
        if let multifragmentMaxRequestSize {
            capabilitySets.append(contentsOf: capabilitySet(
                type: SharePDU.capsetMultifragment,
                value: multifragmentMaxRequestSize
            ))
            capabilityCount += 1
        }

        let sourceDescriptor = Array("MSTSC".utf8)
        var pdu: [UInt8] = []
        pdu.appendU16(0) // totalLength, filled below
        pdu.appendU16(0x0013) // Confirm Active | protocol version
        pdu.appendU16(1002) // pduSource
        pdu.appendU32(0x0001_03EA) // shareId
        pdu.appendU16(1002) // originatorId
        pdu.appendU16(UInt16(sourceDescriptor.count))
        pdu.appendU16(UInt16(capabilitySets.count + 4))
        pdu.append(contentsOf: sourceDescriptor)
        pdu.appendU16(capabilityCount)
        pdu.appendU16(0)
        pdu.append(contentsOf: capabilitySets)
        let totalLength = UInt16(pdu.count)
        pdu[0] = UInt8(totalLength & 0xFF)
        pdu[1] = UInt8(totalLength >> 8)
        return pdu
    }

    private func capabilitySet(type: UInt16, value: UInt32) -> [UInt8] {
        var capability: [UInt8] = []
        capability.appendU16(type)
        capability.appendU16(8)
        capability.appendU32(value)
        return capability
    }
    private func capabilitySet(type: UInt16, value: UInt16) -> [UInt8] {
        var capability: [UInt8] = []
        capability.appendU16(type)
        capability.appendU16(6)
        capability.appendU16(value)
        return capability
    }
}
