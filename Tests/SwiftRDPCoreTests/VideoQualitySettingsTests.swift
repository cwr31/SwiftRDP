import XCTest
@testable import SwiftRDPCore

final class VideoQualitySettingsTests: XCTestCase {
    func testDefaultUsesAutomaticOriginalCeiling() {
        XCTAssertEqual(VideoQualitySettings.default.mode, .automatic)
        XCTAssertEqual(VideoQualitySettings.default.bitrateCeiling, 20_000_000)
        XCTAssertEqual(VideoQualitySettings.default.customBitrate, 30_000_000)
    }

    func testNamedQualityBudgets() {
        XCTAssertEqual(VideoQualitySettings(mode: .original).bitrateCeiling, 20_000_000)
        XCTAssertEqual(VideoQualitySettings(mode: .ultra).bitrateCeiling, 8_000_000)
        XCTAssertEqual(VideoQualitySettings(mode: .high).bitrateCeiling, 2_000_000)
    }

    func testSwitchingModesKeepsCustomBitrate() {
        var quality = VideoQualitySettings(mode: .custom, customBitrate: 50_000_000)
        quality.mode = .high
        XCTAssertEqual(quality.bitrateCeiling, 2_000_000)
        XCTAssertEqual(quality.customBitrate, 50_000_000)
        quality.mode = .automatic
        XCTAssertEqual(quality.bitrateCeiling, 20_000_000)
        quality.mode = .custom
        XCTAssertEqual(quality.bitrateCeiling, 50_000_000)
    }

    func testCustomBitrateIsBoundedOnInitializationAndEditing() {
        var quality = VideoQualitySettings(mode: .custom, customBitrate: Int.max)
        XCTAssertEqual(quality.bitrateCeiling, 500_000_000)
        quality.customBitrate = -1
        XCTAssertEqual(quality.bitrateCeiling, 1_000_000)
        quality.customBitrate = 37_000_000
        XCTAssertEqual(quality.bitrateCeiling, 37_000_000)
    }

    func testDecodingBoundsCustomBitrate() throws {
        for (bitrate, expected) in [(-1, 1_000_000), (600_000_000, 500_000_000)] {
            let data = Data("{\"mode\":\"custom\",\"customBitrate\":\(bitrate)}".utf8)
            let decoded = try JSONDecoder().decode(VideoQualitySettings.self, from: data)
            XCTAssertEqual(decoded.bitrateCeiling, expected)
        }
    }

    func testEveryModeRetainsAdaptiveStartupAndConfiguredCeiling() {
        for mode in VideoQualityMode.allCases {
            let quality = VideoQualitySettings(mode: mode)
            let controller = VideoTargetController(bitrate: quality.bitrateCeiling)
            XCTAssertEqual(controller.configuredBitrate, quality.bitrateCeiling)
            XCTAssertEqual(controller.targetBitrate, min(quality.bitrateCeiling, 4_000_000))
        }
    }
}
