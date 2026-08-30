import XCTest
@testable import SwiftRDPCore

final class DisplayContentLayoutTests: XCTestCase {
    func testAspectsDifferIPadVsMac() {
        // iPad-ish 4:3 vs MacBook 3024×1964
        XCTAssertTrue(
            DisplayContentLayout.aspectsDiffer(2224, 1668, 3024, 1964)
        )
        XCTAssertFalse(
            DisplayContentLayout.aspectsDiffer(1512, 982, 3024, 1964)
        )
    }

    func testPhysicalMirrorPlanForcesPanelWhenAspectDiffers() {
        let plan = DisplayContentLayout.physicalMirrorPlan(
            desktopWidth: 2224,
            desktopHeight: 1668,
            panelWidth: 3024,
            panelHeight: 1964
        )
        // Capture is exactly the panel: padding would shift a scalesToFit stream.
        XCTAssertEqual(plan.captureWidth, 3024)
        XCTAssertEqual(plan.captureHeight, 1964)
        XCTAssertFalse(plan.layout.isLetterboxed)
        XCTAssertEqual(plan.layout.desktopWidth, 3024)
        XCTAssertEqual(plan.layout.desktopHeight, 1964)
        XCTAssertEqual(plan.layout.contentWidth, 3024)
        XCTAssertEqual(plan.layout.contentHeight, 1964)
        XCTAssertEqual(plan.layout.offsetX, 0)
        XCTAssertEqual(plan.layout.offsetY, 0)
    }

    func testPhysicalMirrorPlanFullBleedWhenOneToOne() {
        let plan = DisplayContentLayout.physicalMirrorPlan(
            desktopWidth: 3024,
            desktopHeight: 1964,
            panelWidth: 3024,
            panelHeight: 1964
        )
        XCTAssertEqual(plan.captureWidth, 3024)
        XCTAssertEqual(plan.captureHeight, 1964)
        XCTAssertFalse(plan.layout.isLetterboxed)
        XCTAssertEqual(plan.layout.desktopWidth, 3024)
        XCTAssertEqual(plan.layout.desktopHeight, 1964)
        XCTAssertEqual(plan.layout.offsetX, 0)
        XCTAssertEqual(plan.layout.offsetY, 0)
    }

    func testPhysicalMirrorPlanSameAspectAlsoForcesPanel() {
        let plan = DisplayContentLayout.physicalMirrorPlan(
            desktopWidth: 1512,
            desktopHeight: 982,
            panelWidth: 3024,
            panelHeight: 1964
        )
        XCTAssertEqual(plan.captureWidth, 3024)
        XCTAssertEqual(plan.captureHeight, 1964)
        XCTAssertFalse(plan.layout.isLetterboxed)
        XCTAssertEqual(plan.layout.desktopWidth, 3024)
        XCTAssertEqual(plan.layout.desktopHeight, 1964)
        XCTAssertEqual(plan.layout.contentWidth, 3024)
        XCTAssertEqual(plan.layout.contentHeight, 1964)
    }

    func testMouseMappingThroughLetterbox() {
        let layout = DisplayContentLayout.aspectFit(
            desktopWidth: 2224,
            desktopHeight: 1668,
            sourceWidth: 3024,
            sourceHeight: 1964
        )
        // Top-center of content → top-center of host (CG logical 1512×982).
        let rdpX = layout.offsetX + layout.contentWidth / 2
        let rdpY = layout.offsetY
        let scaleX = 1512.0 / Double(layout.contentWidth)
        let scaleY = 982.0 / Double(layout.contentHeight)
        let hostX = (Double(rdpX) - Double(layout.offsetX)) * scaleX
        let hostY = (Double(rdpY) - Double(layout.offsetY)) * scaleY
        XCTAssertEqual(hostX, 756, accuracy: 1.5)
        XCTAssertEqual(hostY, 0, accuracy: 1.5)
    }

    func testRememberedSourceMapsToArbitraryRDPDesktop() {
        let layout = DisplayContentLayout.aspectFit(
            desktopWidth: 1424,
            desktopHeight: 700,
            sourceWidth: 1920,
            sourceHeight: 1080
        )

        XCTAssertEqual(layout.contentWidth, 1244)
        XCTAssertEqual(layout.contentHeight, 700)
        XCTAssertEqual(layout.offsetX, 90)
        XCTAssertEqual(layout.offsetY, 0)

        let rdpX = layout.offsetX + layout.contentWidth / 2
        let rdpY = layout.offsetY + layout.contentHeight / 2
        let hostX = Double(rdpX - layout.offsetX) * 1920.0 / Double(layout.contentWidth)
        let hostY = Double(rdpY - layout.offsetY) * 1080.0 / Double(layout.contentHeight)
        XCTAssertEqual(hostX, 960, accuracy: 1.0)
        XCTAssertEqual(hostY, 540, accuracy: 1.0)
    }
}
