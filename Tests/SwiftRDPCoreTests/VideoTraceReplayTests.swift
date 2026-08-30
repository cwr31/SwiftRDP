import Foundation
import XCTest
@testable import SwiftRDPCore

final class VideoTraceReplayTests: XCTestCase {
    func testReplayRealVideoStatsTraceKeepsFeedbackSourcesSeparate() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(forResource: "real-video-stats", withExtension: "log")
        )
        let lines = try String(contentsOf: fixtureURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        let controller = VideoTargetController(bitrate: 20_000_000, fps: 60)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var maximumNetworkPressure = 0.0
        var maximumClientPressure = 0.0

        for line in lines {
            let fields = line.split(separator: " ").map(String.init)
            guard let timestamp = fields.first.flatMap({ formatter.date(from: $0) }) else {
                XCTFail("invalid trace timestamp: \(line)")
                continue
            }
            let values = Dictionary(uniqueKeysWithValues: fields.dropFirst().compactMap { field -> (String, String)? in
                let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (parts[0], parts[1])
            })
            guard let ack = number(values["ack"]),
                  let unackedParts = values["unacked"]?.split(separator: "/"),
                  let unacked = Int(unackedParts[0])
            else {
                XCTFail("incomplete trace row: \(line)")
                continue
            }

            if let render = number(values["render"]), render > 0 {
                controller.noteClientRenderTiming(
                    commandDecodeMs: 0,
                    renderMs: Int(render),
                    now: timestamp
                )
            }
            controller.noteFrameAck(
                clientQueue: queueFeedback(values["clientQ"]),
                ackLatencyMs: ack,
                unacked: unacked,
                acknowledgedBytes: 50_000,
                acknowledgementIntervalMs: 100,
                now: timestamp
            )
            let quality = controller.perfSnapshot.quality
            maximumNetworkPressure = max(maximumNetworkPressure, quality.networkPressure)
            maximumClientPressure = max(maximumClientPressure, quality.clientPressure)
        }

        XCTAssertGreaterThan(maximumNetworkPressure, 0)
        XCTAssertGreaterThan(maximumClientPressure, 0)
        XCTAssertGreaterThanOrEqual(controller.targetFPS, VideoTargetController.minAdaptiveFPS)
        XCTAssertLessThanOrEqual(controller.targetFPS, 60)
        XCTAssertLessThanOrEqual(controller.targetBitrate, 20_000_000)
    }

    private func queueFeedback(_ raw: String?) -> ClientQueueFeedback {
        guard let raw else { return .unavailable }
        if raw == "?B" || raw == "unknown" || raw == "unavailable" { return .unavailable }
        guard let bytes = Int(raw.replacingOccurrences(of: "B", with: "")) else {
            return .unavailable
        }
        return bytes > 0 ? .queued(bytes: bytes) : .unavailable
    }

    private func number(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        return Double(
            raw
                .replacingOccurrences(of: "ms", with: "")
                .replacingOccurrences(of: "fps", with: "")
        )
    }
}
