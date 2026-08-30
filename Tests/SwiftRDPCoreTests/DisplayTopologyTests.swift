import CoreGraphics
import XCTest
@testable import SwiftRDPCore

final class DisplayTopologyTests: XCTestCase {
    func testStableIdentitySelectionSurvivesDisplayIDChanges() {
        let displays = [
            DisplayTopology.PhysicalDisplayDescriptor(id: 11, identity: "uuid:panel-a"),
            DisplayTopology.PhysicalDisplayDescriptor(id: 22, identity: "uuid:panel-b")
        ]

        XCTAssertEqual(
            DisplayTopology.selectPhysicalDisplayID(
                from: displays,
                preferredIdentity: "uuid:panel-b",
                mainDisplayID: 11
            ),
            22
        )
    }

    func testStableIdentitySelectionFallsBackToCurrentPrimary() {
        let displays = [
            DisplayTopology.PhysicalDisplayDescriptor(id: 11, identity: "uuid:panel-a"),
            DisplayTopology.PhysicalDisplayDescriptor(id: 22, identity: "uuid:panel-b")
        ]

        XCTAssertEqual(
            DisplayTopology.selectPhysicalDisplayID(
                from: displays,
                preferredIdentity: "uuid:removed-panel",
                mainDisplayID: 22
            ),
            22
        )
    }

    func testDisplayReconfigurationImpactIgnoresLayoutOnlyChanges() {
        XCTAssertEqual(
            DisplayTopology.reconfigurationImpact(flags: [.movedFlag], autoSelectPrimary: true),
            .none
        )
        XCTAssertEqual(
            DisplayTopology.reconfigurationImpact(flags: [.setMainFlag], autoSelectPrimary: false),
            .none
        )
    }

    func testDisplayReconfigurationImpactSeparatesTopologyAndGeometry() {
        XCTAssertEqual(
            DisplayTopology.reconfigurationImpact(flags: [.addFlag], autoSelectPrimary: false),
            .topology
        )
        XCTAssertEqual(
            DisplayTopology.reconfigurationImpact(flags: [.mirrorFlag], autoSelectPrimary: false),
            .topology
        )
        XCTAssertEqual(
            DisplayTopology.reconfigurationImpact(flags: [.setModeFlag], autoSelectPrimary: false),
            .geometry
        )
        XCTAssertEqual(
            DisplayTopology.reconfigurationImpact(
                flags: [.desktopShapeChangedFlag],
                autoSelectPrimary: false
            ),
            .geometry
        )
        XCTAssertEqual(
            DisplayTopology.reconfigurationImpact(flags: [.setMainFlag], autoSelectPrimary: true),
            .geometry
        )
    }

    func testHostDisplayPolicyResolution() {
        XCTAssertEqual(
            DisplayTopology.resolvedMode(policy: .automatic, hasPhysicalDisplay: true),
            .physicalMirror
        )
        XCTAssertEqual(
            DisplayTopology.resolvedMode(policy: .automatic, hasPhysicalDisplay: false),
            .virtualMatchClient
        )
        XCTAssertEqual(
            DisplayTopology.resolvedMode(policy: .virtual, hasPhysicalDisplay: true),
            .virtualMatchClient
        )
    }

    func testVirtualDisplaySignatureIsNotPhysical() {
        XCTAssertTrue(DisplayTopology.isVirtualDisplay(
            vendorID: 0x756E_6B6E,
            modelID: 0x7669_7274
        ))
        XCTAssertTrue(DisplayTopology.isVirtualDisplay(
            vendorID: 0x0472,
            modelID: 0x0001
        ))
        XCTAssertFalse(DisplayTopology.isVirtualDisplay(
            vendorID: 0x0610,
            modelID: 0xB036
        ))
    }

    func testVirtualResolutionOptionsIncludeHiDPIVariants() {
        let options = DisplayTopology.virtualResolutionOptions(
            currentLogicalWidth: 1920,
            currentLogicalHeight: 1080,
            currentHiDPI: false
        )
        let native = options.first {
            $0.pointWidth == 1920 && $0.pointHeight == 1080 && !$0.hiDPI
        }
        let hidpi = options.first {
            $0.pointWidth == 1920 && $0.pointHeight == 1080 && $0.hiDPI
        }
        XCTAssertNotNil(native)
        XCTAssertEqual(native?.width, 1920)
        XCTAssertEqual(native?.height, 1080)
        XCTAssertNotNil(hidpi)
        XCTAssertEqual(hidpi?.width, 3840)
        XCTAssertEqual(hidpi?.height, 2160)
        XCTAssertEqual(hidpi?.title, "1920×1080 (HiDPI)")
    }

    func testVirtualResolutionOptionsMarksCurrentHiDPISelection() {
        let options = DisplayTopology.virtualResolutionOptions(
            currentLogicalWidth: 1920,
            currentLogicalHeight: 1080,
            currentHiDPI: true
        )
        let current = options.first(where: \.isCurrent)
        XCTAssertNotNil(current)
        XCTAssertTrue(current?.hiDPI == true)
        XCTAssertEqual(current?.pointWidth, 1920)
        XCTAssertEqual(current?.pointHeight, 1080)
    }

    func testVirtualOptionsAreCappedAt4KClass() {
        let options = DisplayTopology.virtualResolutionOptions(
            currentLogicalWidth: 3840,
            currentLogicalHeight: 2160,
            currentHiDPI: false
        )

        XCTAssertTrue(options.contains {
            $0.pointWidth == 1920 && $0.pointHeight == 1200 && $0.hiDPI
        })
        XCTAssertTrue(options.contains {
            $0.pointWidth == 3840 && $0.pointHeight == 2160 && !$0.hiDPI
        })
        XCTAssertFalse(options.contains {
            $0.pointWidth == 2560 && $0.pointHeight == 1440 && $0.hiDPI
        })
        XCTAssertFalse(options.contains {
            $0.pointWidth == 3840 && $0.pointHeight == 2160 && $0.hiDPI
        })
        XCTAssertTrue(options.filter(\.hiDPI).allSatisfy {
            $0.width <= 3840 && $0.height <= 2400
        })
        XCTAssertTrue(options.allSatisfy {
            $0.width <= 3840 && $0.height <= 2400
        })
    }

    func testNativeVirtualParametersPreserveAspectRatioAt4KCap() {
        let parameters = VirtualDisplayParameters.native(pixelWidth: 5120, pixelHeight: 2880)

        XCTAssertEqual(parameters.pixelWidth, 3840)
        XCTAssertEqual(parameters.pixelHeight, 2160)
        XCTAssertEqual(parameters.logicalWidth, 3840)
        XCTAssertEqual(parameters.logicalHeight, 2160)
    }

    func testNativeVirtualParametersCapSixteenByTenAt3840By2400() {
        let parameters = VirtualDisplayParameters.native(pixelWidth: 5120, pixelHeight: 3200)

        XCTAssertEqual(parameters.pixelWidth, 3840)
        XCTAssertEqual(parameters.pixelHeight, 2400)
    }

    func testHiDPIModeMatchingRejectsNativeModeWithSamePixelSize() {
        XCTAssertFalse(VirtualDisplayManager.modeMatchesRequest(
            modeWidth: 3840,
            modeHeight: 2160,
            modePixelWidth: 3840,
            modePixelHeight: 2160,
            modeIsHiDPI: false,
            requestedPixelWidth: 3840,
            requestedPixelHeight: 2160,
            requestedLogicalWidth: 1920,
            requestedLogicalHeight: 1080,
            preferHiDPI: true
        ))
    }

    func testHiDPIModeMatchingAcceptsLogicalModeWithTwoTimesBackingPixels() {
        XCTAssertTrue(VirtualDisplayManager.modeMatchesRequest(
            modeWidth: 1920,
            modeHeight: 1080,
            modePixelWidth: 3840,
            modePixelHeight: 2160,
            modeIsHiDPI: true,
            requestedPixelWidth: 3840,
            requestedPixelHeight: 2160,
            requestedLogicalWidth: 1920,
            requestedLogicalHeight: 1080,
            preferHiDPI: true
        ))
    }

    func testNativeModeMatchingRequiresNativeLogicalSize() {
        XCTAssertTrue(VirtualDisplayManager.modeMatchesRequest(
            modeWidth: 1920,
            modeHeight: 1080,
            modePixelWidth: 1920,
            modePixelHeight: 1080,
            modeIsHiDPI: false,
            requestedPixelWidth: 1920,
            requestedPixelHeight: 1080,
            requestedLogicalWidth: 1920,
            requestedLogicalHeight: 1080,
            preferHiDPI: false
        ))
    }
}
