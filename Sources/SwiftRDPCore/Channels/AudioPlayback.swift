import Foundation

/// Classic static-channel audio playback ([MS-RDPEA] / `rdpsnd`).
public final class AudioPlayback: VirtualChannel {
    public let name = "rdpsnd"
    public var send: (([UInt8]) -> Void)?
    /// Called when the confirmed audio window becomes full or drains again.
    /// The callback runs after the audio lock is released.
    public var onFlowControlChanged: ((Bool) -> Void)?

    private enum Message {
        static let close: UInt8 = 0x01
        static let wave: UInt8 = 0x02
        static let waveConfirm: UInt8 = 0x05
        static let training: UInt8 = 0x06
        static let formats: UInt8 = 0x07
        static let qualityMode: UInt8 = 0x0C
    }

    private let lock = NSLock()
    private var channelId: UInt16 = 0
    private var ready = false
    private var playbackEnabled: Bool
    private var handshakeSent = false
    private var nextBlockNumber: UInt8 = 1
    private var negotiatedFormatIndex: UInt16 = 0
    private var openedAt = DispatchTime.now().uptimeNanoseconds
    private var inputFormat: InputFormat?
    private var silenceGate = SilenceGate()
    private var pendingWaves: [PendingWave] = []
    private var pendingFrames = 0
    private var droppedFrames = 0
    private var flowControlActive = false

    private enum Output {
        static let sampleRate = 48_000
        static let channels = 2
        static let bitsPerSample = 16
        /// Cap each WAVE block at 20 ms so a large capture callback cannot turn
        /// into a correspondingly large client-side decode/playback unit.
        static let maxFramesPerPDU = sampleRate / 50
        /// Keep enough audio in flight to cover normal WAN confirmations while
        /// preventing a slow client from accumulating seconds of stale PCM.
        static let maxPendingFrames = sampleRate * 120 / 1_000
        static let maxPendingBlocks = 8
    }

    private struct InputFormat: Equatable {
        let sampleRate: Int
        let channels: Int
    }

    private struct PendingWave {
        let blockNumber: UInt8
        let frames: Int
        let sentAt: UInt64
    }

    private struct SilenceGate {
        private static let signalThreshold: Int32 = 32
        private static let preRollFrames = Output.sampleRate / 20 // 50 ms
        private static let hangoverFrames = Output.sampleRate * 3 / 20 // 150 ms

        private var preRoll = SampleRing(
            capacity: preRollFrames * Output.channels
        )
        private(set) var isOpen = false
        private var hangoverFramesRemaining = 0

        mutating func reset() {
            preRoll.reset()
            isOpen = false
            hangoverFramesRemaining = 0
        }

        mutating func process(_ samples: [Int16]) -> [Int16] {
            let sampleCount = samples.count - samples.count % Output.channels
            guard sampleCount > 0 else { return [] }
            let completeSamples = samples.prefix(sampleCount)

            if Self.containsSignal(completeSamples) {
                hangoverFramesRemaining = Self.hangoverFrames
                guard !isOpen else {
                    return sampleCount == samples.count ? samples : Array(completeSamples)
                }

                isOpen = true
                var output = preRoll.drain()
                output.append(contentsOf: completeSamples)
                return output
            }

            guard isOpen else {
                preRoll.append(completeSamples)
                return []
            }

            let frameCount = completeSamples.count / Output.channels
            let framesToSend = min(frameCount, hangoverFramesRemaining)
            let samplesToSend = framesToSend * Output.channels
            let output: [Int16]
            if samplesToSend == samples.count {
                output = samples
            } else {
                output = Array(completeSamples.prefix(samplesToSend))
            }
            hangoverFramesRemaining -= framesToSend

            if samplesToSend < completeSamples.count {
                preRoll.append(completeSamples.dropFirst(samplesToSend))
            }
            if hangoverFramesRemaining == 0 {
                isOpen = false
            }
            return output
        }

        private static func containsSignal(_ samples: ArraySlice<Int16>) -> Bool {
            samples.contains { sample in
                let value = Int32(sample)
                let magnitude = value < 0 ? -value : value
                return magnitude >= signalThreshold
            }
        }
    }

    private struct SampleRing {
        private var storage: [Int16]
        private var writeIndex = 0
        private var sampleCount = 0

        init(capacity: Int) {
            storage = [Int16](repeating: 0, count: capacity)
        }

        mutating func reset() {
            writeIndex = 0
            sampleCount = 0
        }

        mutating func append(_ samples: ArraySlice<Int16>) {
            guard !storage.isEmpty, !samples.isEmpty else { return }
            if samples.count >= storage.count {
                storage.replaceSubrange(
                    storage.indices,
                    with: samples.suffix(storage.count)
                )
                writeIndex = 0
                sampleCount = storage.count
                return
            }

            for sample in samples {
                storage[writeIndex] = sample
                writeIndex = (writeIndex + 1) % storage.count
            }
            sampleCount = min(storage.count, sampleCount + samples.count)
        }

        mutating func drain() -> [Int16] {
            guard sampleCount > 0 else { return [] }
            let start = (writeIndex - sampleCount + storage.count) % storage.count
            var samples = [Int16]()
            samples.reserveCapacity(sampleCount)
            let firstCount = min(sampleCount, storage.count - start)
            samples.append(contentsOf: storage[start..<(start + firstCount)])
            if firstCount < sampleCount {
                samples.append(contentsOf: storage[0..<(sampleCount - firstCount)])
            }
            reset()
            return samples
        }
    }

    public init(playbackEnabled: Bool = true) {
        self.playbackEnabled = playbackEnabled
    }

    public func setPlaybackEnabled(_ enabled: Bool) {
        lock.lock()
        guard playbackEnabled != enabled else {
            lock.unlock()
            return
        }
        playbackEnabled = enabled
        let callback = resetAudioStreamLocked() ? onFlowControlChanged : nil
        lock.unlock()
        callback?(false)
        RDPLog.channels.info("Audio: remote playback \(enabled ? "enabled" : "disabled")")
    }

    public func onOpen(channelId: UInt16) {
        lock.lock()
        self.channelId = channelId
        ready = false
        handshakeSent = false
        nextBlockNumber = 1
        negotiatedFormatIndex = 0
        openedAt = DispatchTime.now().uptimeNanoseconds
        let callback = resetAudioStreamLocked() ? onFlowControlChanged : nil
        lock.unlock()
        callback?(false)
        // Do not send Server Audio Formats here — with SKIP_CHANNELJOIN, onOpen runs
        // right after MCS Connect Response, before Client Info. Early rdpsnd PDUs make
        // mstsc abort with protocol error 0xd06.
        RDPLog.channels.info("Audio: rdpsnd channel open id=\(channelId)")
    }

    /// MS-RDPEA: server offers formats after Demand Active in the deferred handshake window.
    public func startHandshakeIfNeeded() {
        lock.lock()
        let id = channelId
        let already = handshakeSent
        if id != 0, !already {
            handshakeSent = true
        }
        lock.unlock()
        guard id != 0, !already else { return }
        sendServerFormats()
        RDPLog.channels.info("Audio: sent Server Audio Formats")
    }

    public func onData(_ data: [UInt8]) {
        guard data.count >= 4 else {
            RDPLog.channels.error("Audio: short rdpsnd PDU (\(data.count)B)")
            return
        }
        let message = data[0]
        let bodySize = Int(u16(data, 2))
        guard bodySize <= data.count - 4 else {
            RDPLog.channels.error("Audio: incomplete rdpsnd PDU type=0x\(String(message, radix: 16))")
            return
        }
        let body = Array(data[4..<(4 + bodySize)])

        switch message {
        case Message.formats:
            handleClientFormats(body)
        case Message.waveConfirm:
            if body.count >= 4 {
                handleWaveConfirm(blockNumber: body[2])
            }
        case Message.training:
            // The Training Confirm PDU has the same timestamp/packet-size body.
            sendPDU(type: Message.training, body: body)
            RDPLog.channels.debug("Audio: training echoed")
        case Message.qualityMode:
            let quality = body.count >= 2 ? u16(body, 0) : 0
            RDPLog.channels.info("Audio: client quality mode=\(quality)")
        case Message.close:
            lock.lock()
            ready = false
            let callback = resetAudioStreamLocked() ? onFlowControlChanged : nil
            lock.unlock()
            callback?(false)
            RDPLog.channels.info("Audio: client closed playback")
        default:
            RDPLog.channels.debug("Audio: ignored rdpsnd type=0x\(String(message, radix: 16))")
        }
    }

    public func onClose() {
        lock.lock()
        let oldChannelId = channelId
        channelId = 0
        ready = false
        let callback = resetAudioStreamLocked() ? onFlowControlChanged : nil
        lock.unlock()
        callback?(false)
        RDPLog.channels.info("Audio: rdpsnd channel closed id=\(oldChannelId)")
    }

    /// Feed PCM captured by ScreenCaptureKit. Input is converted to negotiated 48 kHz stereo Int16.
    public func enqueuePCM(_ samples: [Int16], sampleRate: Int, channels: Int) {
        guard !samples.isEmpty, sampleRate > 0, channels > 0 else { return }

        lock.lock()
        let canSend = playbackEnabled && ready && channelId != 0
        lock.unlock()
        guard canSend else { return }

        let stereo = Self.convertToStereo48k(samples, sampleRate: sampleRate, channels: channels)
        guard !stereo.isEmpty else { return }

        let format = InputFormat(sampleRate: sampleRate, channels: channels)
        lock.lock()
        guard playbackEnabled, ready, channelId != 0 else {
            lock.unlock()
            return
        }
        if inputFormat != format {
            inputFormat = format
            silenceGate.reset()
        }
        let wasOpen = silenceGate.isOpen
        let gatedStereo = silenceGate.process(stereo)
        let isOpen = silenceGate.isOpen
        lock.unlock()

        if !wasOpen, isOpen {
            RDPLog.channels.debug("Audio: signal detected; resuming PCM")
        } else if wasOpen, !isOpen {
            RDPLog.channels.debug("Audio: silence detected; suppressing PCM")
        }
        guard !gatedStereo.isEmpty else { return }

        // Keep each logical audio PDU modest; the router performs static-channel fragmentation.
        var frameOffset = 0
        let frameCount = gatedStereo.count / Output.channels
        while frameOffset < frameCount {
            let frames = min(Output.maxFramesPerPDU, frameCount - frameOffset)
            let firstSample = frameOffset * Output.channels
            let sampleCount = frames * Output.channels
            let chunk = gatedStereo[firstSample..<(firstSample + sampleCount)]
            let pcm = Self.littleEndianBytes(chunk)

            lock.lock()
            guard playbackEnabled, ready, channelId != 0 else {
                lock.unlock()
                return
            }
            guard pendingFrames + frames <= Output.maxPendingFrames,
                  pendingWaves.count < Output.maxPendingBlocks else {
                droppedFrames += frameCount - frameOffset
                let notify = !flowControlActive
                flowControlActive = true
                let callback = notify ? onFlowControlChanged : nil
                lock.unlock()
                callback?(true)
                return
            }
            let block = nextBlockNumber
            nextBlockNumber &+= 1
            let formatIndex = negotiatedFormatIndex
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = now &- openedAt
            let timestamp = UInt16(truncatingIfNeeded: elapsed / 1_000_000)
            pendingWaves.append(PendingWave(blockNumber: block, frames: frames, sentAt: now))
            pendingFrames += frames
            lock.unlock()

            sendWave(
                pcm: pcm,
                timestamp: timestamp,
                formatIndex: formatIndex,
                blockNumber: block
            )
            frameOffset += frames
        }
    }

    private func handleWaveConfirm(blockNumber: UInt8) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard let confirmedIndex = pendingWaves.firstIndex(where: {
            $0.blockNumber == blockNumber
        }) else {
            lock.unlock()
            RDPLog.channels.debug("Audio: ignored stale wave confirm block=\(blockNumber)")
            return
        }

        let confirmed = pendingWaves[confirmedIndex]
        let consumedFrames = pendingWaves[...confirmedIndex].reduce(0) { $0 + $1.frames }
        pendingWaves.removeFirst(confirmedIndex + 1)
        pendingFrames -= consumedFrames
        let latencyMs = (now &- confirmed.sentAt) / 1_000_000
        let recovered = flowControlActive
        let dropped = droppedFrames
        let callback = recovered ? onFlowControlChanged : nil
        if recovered {
            flowControlActive = false
            droppedFrames = 0
        }
        let remainingFrames = pendingFrames
        lock.unlock()

        if recovered {
            callback?(false)
            let droppedMs = dropped * 1_000 / Output.sampleRate
            let pendingMs = remainingFrames * 1_000 / Output.sampleRate
            RDPLog.channels.info(
                "Audio: live window resumed confirm=\(latencyMs)ms " +
                "dropped=\(droppedMs)ms pending=\(pendingMs)ms"
            )
        } else {
            RDPLog.channels.debug(
                "Audio: wave confirmed block=\(blockNumber) latency=\(latencyMs)ms"
            )
        }
    }

    private func sendServerFormats() {
        var body: [UInt8] = []
        body.appendU32(0x0000_0001) // TSSNDCAPS_ALIVE
        body.appendU32(0xFFFF_FFFF) // initial volume
        body.appendU32(0) // pitch
        body.appendU16(0) // Static-channel port field is unused.
        body.appendU16(1) // number of formats
        body.append(0) // last block confirmed
        body.appendU16(0x0006) // RDPEA version 6
        body.append(0)

        body.appendU16(0x0001) // WAVE_FORMAT_PCM
        body.appendU16(UInt16(Output.channels))
        body.appendU32(UInt32(Output.sampleRate))
        let blockAlign = Output.channels * Output.bitsPerSample / 8
        body.appendU32(UInt32(Output.sampleRate * blockAlign))
        body.appendU16(UInt16(blockAlign))
        body.appendU16(UInt16(Output.bitsPerSample))
        body.appendU16(0) // cbSize
        sendPDU(type: Message.formats, body: body)
    }

    private func handleClientFormats(_ body: [UInt8]) {
        guard body.count >= 20 else {
            RDPLog.channels.error("Audio: short Client Audio Formats PDU")
            return
        }
        let count = Int(u16(body, 14))
        var offset = 20
        var acceptedFormatIndex: UInt16?
        for formatIndex in 0..<count {
            guard offset + 18 <= body.count else { break }
            let tag = u16(body, offset)
            let channels = Int(u16(body, offset + 2))
            let rate = Int(u32(body, offset + 4))
            let bits = Int(u16(body, offset + 14))
            let extra = Int(u16(body, offset + 16))
            if tag == 0x0001,
               channels == Output.channels,
               rate == Output.sampleRate,
               bits == Output.bitsPerSample {
                acceptedFormatIndex = UInt16(formatIndex)
            }
            offset += 18 + extra
        }

        lock.lock()
        ready = acceptedFormatIndex != nil
        negotiatedFormatIndex = acceptedFormatIndex ?? 0
        let callback = resetAudioStreamLocked() ? onFlowControlChanged : nil
        lock.unlock()
        callback?(false)
        if let acceptedFormatIndex {
            RDPLog.channels.info("Audio: client accepted PCM \(Output.sampleRate)Hz \(Output.channels)ch \(Output.bitsPerSample)-bit")
            RDPLog.channels.debug("Audio: negotiated client format index=\(acceptedFormatIndex)")
        } else {
            RDPLog.channels.info("Audio: client did not accept offered PCM format")
        }
    }

    private func sendPDU(type: UInt8, body: [UInt8]) {
        guard body.count <= Int(UInt16.max) else {
            RDPLog.channels.error("Audio: dropping oversized rdpsnd PDU (\(body.count)B)")
            return
        }
        var pdu: [UInt8] = [type, 0]
        pdu.appendU16(UInt16(body.count))
        pdu.append(contentsOf: body)
        send?(pdu)
    }

    /// SNDC_WAVE is the RDPEA special two-packet form: WaveInfo followed by raw Wave data.
    private func sendWave(
        pcm: [UInt8],
        timestamp: UInt16,
        formatIndex: UInt16,
        blockNumber: UInt8
    ) {
        guard pcm.count >= 4, pcm.count + 8 <= Int(UInt16.max) else { return }

        var waveInfo: [UInt8] = [Message.wave, 0]
        waveInfo.appendU16(UInt16(pcm.count + 8))
        waveInfo.appendU16(timestamp)
        waveInfo.appendU16(formatIndex)
        waveInfo.append(blockNumber)
        waveInfo.append(contentsOf: [0, 0, 0])
        waveInfo.append(contentsOf: pcm.prefix(4))
        send?(waveInfo)

        // The client replaces these first four padding bytes with WaveInfo's Data field.
        var waveData: [UInt8] = [0, 0, 0, 0]
        waveData.append(contentsOf: pcm.dropFirst(4))
        send?(waveData)
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

    @discardableResult
    private func resetAudioStreamLocked() -> Bool {
        let wasFlowControlled = flowControlActive
        inputFormat = nil
        silenceGate.reset()
        pendingWaves.removeAll(keepingCapacity: true)
        pendingFrames = 0
        droppedFrames = 0
        flowControlActive = false
        return wasFlowControlled
    }

    private static func convertToStereo48k(
        _ samples: [Int16],
        sampleRate: Int,
        channels: Int
    ) -> [Int16] {
        let inputFrames = samples.count / channels
        guard inputFrames > 0 else { return [] }
        let completeSampleCount = inputFrames * channels

        // ScreenCaptureKit is configured for this exact format. Preserve the
        // array's copy-on-write storage instead of rebuilding every sample.
        if sampleRate == Output.sampleRate, channels == Output.channels {
            return completeSampleCount == samples.count
                ? samples
                : Array(samples.prefix(completeSampleCount))
        }

        var stereo = [Int16]()
        stereo.reserveCapacity(inputFrames * Output.channels)
        for frame in 0..<inputFrames {
            let base = frame * channels
            if channels == 1 {
                stereo.append(samples[base])
                stereo.append(samples[base])
            } else {
                stereo.append(samples[base])
                stereo.append(samples[base + 1])
            }
        }
        guard sampleRate != Output.sampleRate else { return stereo }

        let outputFrames = max(
            1,
            Int((Double(inputFrames) * Double(Output.sampleRate) / Double(sampleRate)).rounded())
        )
        var result = [Int16](repeating: 0, count: outputFrames * Output.channels)
        for outputFrame in 0..<outputFrames {
            let sourcePosition = Double(outputFrame) * Double(sampleRate) / Double(Output.sampleRate)
            let lower = min(Int(sourcePosition), inputFrames - 1)
            let upper = min(lower + 1, inputFrames - 1)
            let fraction = sourcePosition - Double(lower)
            for channel in 0..<Output.channels {
                let a = Double(stereo[lower * Output.channels + channel])
                let b = Double(stereo[upper * Output.channels + channel])
                result[outputFrame * Output.channels + channel] = Int16(
                    clamping: Int((a + (b - a) * fraction).rounded())
                )
            }
        }
        return result
    }

    private static func littleEndianBytes(_ samples: ArraySlice<Int16>) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(samples.count * 2)
        for sample in samples {
            let value = UInt16(bitPattern: sample)
            bytes.append(UInt8(value & 0xFF))
            bytes.append(UInt8(value >> 8))
        }
        return bytes
    }
}
