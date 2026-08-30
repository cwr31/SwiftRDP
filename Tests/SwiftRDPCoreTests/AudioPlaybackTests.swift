import XCTest
@testable import SwiftRDPCore

final class AudioPlaybackTests: XCTestCase {
    func testOffersPCMAndSendsWaveAfterClientAcceptsFormat() {
        let audio = AudioPlayback()
        let sink = PacketSink()
        audio.send = { sink.packets.append($0) }

        audio.onOpen(channelId: 1004)
        XCTAssertTrue(sink.packets.isEmpty)
        audio.startHandshakeIfNeeded()

        XCTAssertEqual(sink.packets.count, 1)
        guard sink.packets.count == 1 else { return }
        XCTAssertEqual(sink.packets[0][0], 0x07)
        XCTAssertEqual(u16(sink.packets[0], 4 + 14), 1)
        XCTAssertEqual(u16(sink.packets[0], 4 + 20), 0x0001)
        XCTAssertEqual(u32(sink.packets[0], 4 + 24), 48_000)

        audio.onData(clientFormatsPDU())
        sink.packets.removeAll()
        audio.enqueuePCM([1_024, -1_024, 2_048, -2_048], sampleRate: 48_000, channels: 2)

        XCTAssertEqual(sink.packets.count, 2)
        guard sink.packets.count == 2 else { return }
        let wave = sink.packets[0]
        XCTAssertEqual(wave[0], 0x02)
        XCTAssertEqual(Int(u16(wave, 2)), 16)
        XCTAssertEqual(u16(wave, 4 + 2), 0)
        XCTAssertEqual(Array(wave.suffix(4)), [0, 4, 0, 252])
        XCTAssertEqual(sink.packets[1], [0, 0, 0, 0, 0, 8, 0, 248])
    }

    func testDoesNotSendAudioBeforeFormatNegotiation() {
        let audio = AudioPlayback()
        let sink = PacketSink()
        audio.send = { sink.packets.append($0) }
        audio.onOpen(channelId: 1004)

        audio.enqueuePCM([1_024, 1_024], sampleRate: 48_000, channels: 2)
        XCTAssertTrue(sink.packets.isEmpty)

        audio.startHandshakeIfNeeded()
        audio.enqueuePCM([1_024, 1_024], sampleRate: 48_000, channels: 2)

        XCTAssertEqual(sink.packets.count, 1)
        XCTAssertEqual(sink.packets[0][0], 0x07)
    }

    func testRemotePlaybackTogglesWithoutRenegotiating() {
        let (audio, sink) = makeNegotiatedAudio()

        audio.setPlaybackEnabled(false)
        audio.enqueuePCM([1_024, -1_024], sampleRate: 48_000, channels: 2)
        XCTAssertTrue(sink.packets.isEmpty)

        audio.setPlaybackEnabled(true)
        audio.enqueuePCM([1_024, -1_024], sampleRate: 48_000, channels: 2)
        XCTAssertEqual(sink.packets.count, 2)
    }

    func testReportsAudioQueuePressureAndRecovery() {
        let (audio, sink) = makeNegotiatedAudio()
        var pressureEvents: [Bool] = []
        audio.onFlowControlChanged = { pressureEvents.append($0) }
        let signal = [Int16](repeating: 1_024, count: 960 * 2)

        // Six 20 ms blocks fill the confirmed audio window; the next block is
        // dropped and reports pressure instead of growing stale PCM latency.
        for _ in 0..<7 {
            audio.enqueuePCM(signal, sampleRate: 48_000, channels: 2)
        }
        XCTAssertEqual(pressureEvents, [true])

        confirmLastWave(audio, packets: sink.packets)
        XCTAssertEqual(pressureEvents, [true, false])
    }

    func testInitiallyDormantPlaybackCanEnableAfterNegotiation() {
        let audio = AudioPlayback(playbackEnabled: false)
        let sink = PacketSink()
        audio.send = { sink.packets.append($0) }
        audio.onOpen(channelId: 1004)
        audio.startHandshakeIfNeeded()
        audio.onData(clientFormatsPDU())
        sink.packets.removeAll()

        audio.enqueuePCM([1_024, -1_024], sampleRate: 48_000, channels: 2)
        XCTAssertTrue(sink.packets.isEmpty)

        audio.setPlaybackEnabled(true)
        audio.enqueuePCM([1_024, -1_024], sampleRate: 48_000, channels: 2)
        XCTAssertEqual(sink.packets.count, 2)
    }

    func testContinuousSilenceIsNotSent() {
        let (audio, sink) = makeNegotiatedAudio()
        let silence = [Int16](repeating: 0, count: 4_800 * 2)

        for _ in 0..<5 {
            audio.enqueuePCM(silence, sampleRate: 48_000, channels: 2)
        }

        XCTAssertTrue(sink.packets.isEmpty)
    }

    func testSignalIncludesBoundedPreRoll() {
        let (audio, sink) = makeNegotiatedAudio()
        let quietFrames = 4_800
        let quiet = (0..<(quietFrames * 2)).map { $0.isMultiple(of: 2) ? Int16(8) : Int16(-8) }
        audio.enqueuePCM(quiet, sampleRate: 48_000, channels: 2)

        audio.enqueuePCM([1_024, -1_024], sampleRate: 48_000, channels: 2)

        let samples = waveSamples(sink.packets)
        XCTAssertEqual(samples.count, (2_400 + 1) * 2)
        XCTAssertEqual(Array(samples.prefix(4)), [8, -8, 8, -8])
        XCTAssertEqual(Array(samples.suffix(2)), [1_024, -1_024])
    }

    func testSilenceIsSentOnlyDuringHangover() {
        let (audio, sink) = makeNegotiatedAudio()
        audio.enqueuePCM([1_024, -1_024], sampleRate: 48_000, channels: 2)
        confirmLastWave(audio, packets: sink.packets)
        sink.packets.removeAll()

        let oneHundredMilliseconds = [Int16](repeating: 0, count: 4_800 * 2)
        audio.enqueuePCM(oneHundredMilliseconds, sampleRate: 48_000, channels: 2)
        XCTAssertEqual(waveSamples(sink.packets).count, 4_800 * 2)
        confirmLastWave(audio, packets: sink.packets)

        sink.packets.removeAll()
        audio.enqueuePCM(oneHundredMilliseconds, sampleRate: 48_000, channels: 2)
        XCTAssertEqual(waveSamples(sink.packets).count, 2_400 * 2)

        sink.packets.removeAll()
        audio.enqueuePCM(oneHundredMilliseconds, sampleRate: 48_000, channels: 2)
        XCTAssertTrue(sink.packets.isEmpty)
    }

    func testInputFormatChangeResetsOpenGate() {
        let (audio, sink) = makeNegotiatedAudio()
        audio.enqueuePCM([1_024, -1_024], sampleRate: 48_000, channels: 2)
        sink.packets.removeAll()

        let silence = [Int16](repeating: 0, count: 4_410 * 2)
        audio.enqueuePCM(silence, sampleRate: 44_100, channels: 2)

        XCTAssertTrue(sink.packets.isEmpty)
    }

    func testLargeCaptureCallbackIsSplitIntoTwentyMillisecondWaveBlocks() {
        let (audio, sink) = makeNegotiatedAudio()
        let frames = 4_800
        let signal = (0..<(frames * 2)).map { $0.isMultiple(of: 2) ? Int16(1_024) : Int16(-1_024) }

        audio.enqueuePCM(signal, sampleRate: 48_000, channels: 2)

        XCTAssertEqual(sink.packets.count, 10)
        XCTAssertEqual(waveSamples(sink.packets).count, frames * 2)
        for index in stride(from: 0, to: sink.packets.count, by: 2) {
            XCTAssertEqual(Int(u16(sink.packets[index], 2)), 960 * 4 + 8)
        }
    }

    func testUnconfirmedAudioIsBoundedAndNewestAudioResumesAfterConfirmation() {
        let (audio, sink) = makeNegotiatedAudio()
        let signal = [Int16](repeating: 1_024, count: 4_800 * 2)

        audio.enqueuePCM(signal, sampleRate: 48_000, channels: 2)
        XCTAssertEqual(waveBlocks(sink.packets).count, 5)

        audio.enqueuePCM(signal, sampleRate: 48_000, channels: 2)
        XCTAssertEqual(waveBlocks(sink.packets).count, 6)

        let confirmedBlock = waveBlocks(sink.packets)[2]
        audio.onData(waveConfirmPDU(blockNumber: confirmedBlock))
        audio.enqueuePCM([2_048, -2_048], sampleRate: 48_000, channels: 2)

        XCTAssertEqual(waveBlocks(sink.packets).count, 7)
        XCTAssertEqual(Array(waveSamples(Array(sink.packets.suffix(2))).suffix(2)), [2_048, -2_048])
    }

    func testWaveConfirmHandlesBlockNumberWraparound() {
        let (audio, sink) = makeNegotiatedAudio()
        let sample = [Int16](repeating: 1_024, count: 2)

        for _ in 0..<260 {
            audio.enqueuePCM(sample, sampleRate: 48_000, channels: 2)
            let block = waveBlocks(sink.packets).last!
            audio.onData(waveConfirmPDU(blockNumber: block))
        }

        let blocks = waveBlocks(sink.packets)
        XCTAssertEqual(blocks[0], 1)
        XCTAssertEqual(blocks[254], 255)
        XCTAssertEqual(blocks[255], 0)
        XCTAssertEqual(blocks[259], 4)
    }

    func testClientFormatRenegotiationResetsOpenGate() {
        let (audio, sink) = makeNegotiatedAudio()
        audio.enqueuePCM([1_024, -1_024], sampleRate: 48_000, channels: 2)
        sink.packets.removeAll()

        audio.onData(clientFormatsPDU())
        audio.enqueuePCM([0, 0], sampleRate: 48_000, channels: 2)

        XCTAssertTrue(sink.packets.isEmpty)
    }

    func testSessionRestartResetsOpenGate() {
        let (audio, sink) = makeNegotiatedAudio()
        audio.enqueuePCM([1_024, -1_024], sampleRate: 48_000, channels: 2)
        audio.onClose()
        audio.onOpen(channelId: 1005)
        audio.startHandshakeIfNeeded()
        audio.onData(clientFormatsPDU())
        sink.packets.removeAll()

        audio.enqueuePCM([0, 0], sampleRate: 48_000, channels: 2)

        XCTAssertTrue(sink.packets.isEmpty)
    }

    private final class PacketSink {
        var packets: [[UInt8]] = []
    }

    private func makeNegotiatedAudio() -> (AudioPlayback, PacketSink) {
        let audio = AudioPlayback()
        let sink = PacketSink()
        audio.send = { sink.packets.append($0) }
        audio.onOpen(channelId: 1004)
        audio.startHandshakeIfNeeded()
        audio.onData(clientFormatsPDU())
        sink.packets.removeAll()
        return (audio, sink)
    }

    private func waveSamples(_ packets: [[UInt8]]) -> [Int16] {
        guard packets.count.isMultiple(of: 2) else {
            XCTFail("SNDC_WAVE output must contain WaveInfo/WaveData pairs")
            return []
        }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: packets.count, by: 2) {
            let waveInfo = packets[index]
            let waveData = packets[index + 1]
            XCTAssertEqual(waveInfo.first, 0x02)
            XCTAssertGreaterThanOrEqual(waveInfo.count, 12)
            XCTAssertGreaterThanOrEqual(waveData.count, 4)
            bytes.append(contentsOf: waveInfo.suffix(4))
            bytes.append(contentsOf: waveData.dropFirst(4))
        }
        guard bytes.count.isMultiple(of: 2) else {
            XCTFail("PCM payload must contain complete Int16 samples")
            return []
        }
        return stride(from: 0, to: bytes.count, by: 2).map { index in
            Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
        }
    }

    private func waveBlocks(_ packets: [[UInt8]]) -> [UInt8] {
        stride(from: 0, to: packets.count, by: 2).map { packets[$0][8] }
    }

    private func waveConfirmPDU(blockNumber: UInt8) -> [UInt8] {
        [0x05, 0, 4, 0, 0, 0, blockNumber, 0]
    }

    private func confirmLastWave(_ audio: AudioPlayback, packets: [[UInt8]]) {
        guard let block = waveBlocks(packets).last else { return }
        audio.onData(waveConfirmPDU(blockNumber: block))
    }

    private func clientFormatsPDU() -> [UInt8] {
        var body: [UInt8] = []
        body.appendU32(1)
        body.appendU32(0xFFFF_FFFF)
        body.appendU32(0)
        body.appendU16(0)
        body.appendU16(1)
        body.append(0)
        body.appendU16(6)
        body.append(0)
        body.appendU16(1)
        body.appendU16(2)
        body.appendU32(48_000)
        body.appendU32(192_000)
        body.appendU16(4)
        body.appendU16(16)
        body.appendU16(0)

        var pdu: [UInt8] = [0x07, 0]
        pdu.appendU16(UInt16(body.count))
        pdu.append(contentsOf: body)
        return pdu
    }

    private func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
