import XCTest
@testable import SwiftRDPCore

final class DisplayContentLayoutTests: XCTestCase {
    func testSmallAspectMismatchStillUsesAnAspectFitRect() {
        let layout = DisplayContentLayout.aspectFit(
            desktopWidth: 1920, desktopHeight: 1080,
            sourceWidth: 1920, sourceHeight: 1081
        )
        XCTAssertEqual(layout.contentWidth, 1918)
        XCTAssertEqual(layout.contentHeight, 1080)
        XCTAssertEqual(layout.offsetX, 1)
    }

    func testIPadDesktopPreservesPanelAspect() {
        let layout = DisplayContentLayout.aspectFit(
            desktopWidth: 2224,
            desktopHeight: 1668,
            sourceWidth: 3024,
            sourceHeight: 1964
        )
        XCTAssertEqual(layout.desktopWidth, 2224)
        XCTAssertEqual(layout.desktopHeight, 1668)
        XCTAssertEqual(layout.contentWidth, 2224)
        XCTAssertEqual(layout.contentHeight, 1444)
        XCTAssertEqual(layout.offsetX, 0)
        XCTAssertEqual(layout.offsetY, 112)
    }

    func testIPhoneLandscapePreservesPanelAspect() {
        let layout = DisplayContentLayout.aspectFit(
            desktopWidth: 1424,
            desktopHeight: 700,
            sourceWidth: 3024,
            sourceHeight: 1964
        )

        XCTAssertEqual(layout.desktopWidth, 1424)
        XCTAssertEqual(layout.desktopHeight, 700)
        XCTAssertEqual(layout.contentWidth, 1078)
        XCTAssertEqual(layout.contentHeight, 700)
        XCTAssertEqual(layout.offsetX, 173)
        XCTAssertEqual(layout.offsetY, 0)
        XCTAssertEqual(
            Double(layout.contentWidth) / Double(layout.contentHeight),
            3024.0 / 1964.0,
            accuracy: 0.002
        )
    }

    func testIPhonePortraitPreservesPanelAspect() {
        let layout = DisplayContentLayout.aspectFit(
            desktopWidth: 700,
            desktopHeight: 1424,
            sourceWidth: 3024,
            sourceHeight: 1964
        )

        XCTAssertEqual(layout.desktopWidth, 700)
        XCTAssertEqual(layout.desktopHeight, 1424)
        XCTAssertEqual(layout.contentWidth, 700)
        XCTAssertEqual(layout.contentHeight, 454)
        XCTAssertEqual(layout.offsetX, 0)
        XCTAssertEqual(layout.offsetY, 485)
    }

    func testPanelSizedDesktopHasNoBars() {
        let layout = DisplayContentLayout.aspectFit(
            desktopWidth: 3024,
            desktopHeight: 1964,
            sourceWidth: 3024,
            sourceHeight: 1964
        )
        XCTAssertEqual(layout.desktopWidth, 3024)
        XCTAssertEqual(layout.desktopHeight, 1964)
        XCTAssertEqual(layout.offsetX, 0)
        XCTAssertEqual(layout.offsetY, 0)
    }

    func testSameAspectKeepsSmallerClientDesktop() {
        let layout = DisplayContentLayout.aspectFit(
            desktopWidth: 1512,
            desktopHeight: 982,
            sourceWidth: 3024,
            sourceHeight: 1964
        )
        XCTAssertEqual(layout.desktopWidth, 1512)
        XCTAssertEqual(layout.desktopHeight, 982)
        XCTAssertEqual(layout.contentWidth, 1512)
        XCTAssertEqual(layout.contentHeight, 982)
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
