import Foundation
import NIO
import NIOSSL
import NIOTLS

/// `NIOTransport` — per-connection TCP + atomic X.224 CC → TLS adapter.
public final class NIOTransport {
    public let session: RDPSession
    public let inboundHandler: NIOInboundHandler

    public init(session: RDPSession, sslContext: NIOSSLContext) {
        self.session = session
        self.inboundHandler = NIOInboundHandler(session: session, sslContext: sslContext)
    }
}

/// `NIOInboundHandler` — ByteBuffer inbound, prioritized outbound writes, writability →
/// GFX pause, atomic TLS promote.
public final class NIOInboundHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    private struct OutboundQueue {
        private var storage: [[UInt8]] = []
        private var head = 0
        private(set) var byteCount = 0

        var isEmpty: Bool { head >= storage.count }

        mutating func append(_ bytes: [UInt8]) {
            storage.append(bytes)
            byteCount += bytes.count
        }

        mutating func popFirst() -> [UInt8]? {
            guard head < storage.count else { return nil }
            let bytes = storage[head]
            head += 1
            byteCount -= bytes.count
            compactIfNeeded()
            return bytes
        }

        mutating func removeAll() {
            storage.removeAll(keepingCapacity: false)
            head = 0
            byteCount = 0
        }

        private mutating func compactIfNeeded() {
            guard head > 64, head * 2 >= storage.count else { return }
            storage = Array(storage[head...])
            head = 0
        }
    }

    private let session: RDPSession
    private let sslContext: NIOSSLContext
    private var sslAdded = false
    private var handshakeTimeoutTask: Scheduled<Void>?
    private let outboundLock = NSLock()
    private var pendingAudioWrites = OutboundQueue()
    private var pendingControlWrites = OutboundQueue()
    private var pendingVideoWrites = OutboundQueue()
    private var outboundDrainScheduled = false

    private static let audioBatchByteLimit = 8 * 1024
    private static let controlBatchByteLimit = 64 * 1024
    private static let videoBatchByteLimit = 64 * 1024
    private static let drainTimeLimitNanoseconds: UInt64 = 1_000_000
    private static let maxQueuedAudioBytes = 256 * 1024
    private static let maxQueuedControlBytes = 4 * 1024 * 1024
    private static let maxVideoWriteBytes = 16 * 1024 * 1024

    public init(session: RDPSession, sslContext: NIOSSLContext) {
        self.session = session
        self.sslContext = sslContext
    }

    public func channelActive(context: ChannelHandlerContext) {
        // Kicked during register (single-session) before onClose was wired — drop now.
        if session.phase == .terminated {
            RDPLog.io.info("NIO: closing displaced connection before handshake")
            context.close(promise: nil)
            return
        }
        RDPLog.io.info("Client connected \(context.remoteAddress?.description ?? "?")")
        if let host = context.remoteAddress?.ipAddress, !host.isEmpty {
            session.notePeerHost(host)
        } else if let desc = context.remoteAddress?.description {
            session.notePeerHost(desc)
        }
        handshakeTimeoutTask = context.eventLoop.scheduleTask(in: .seconds(20)) { [weak self, weak context] in
            guard let self, let context, self.session.phase != .active else { return }
            RDPLog.io.info("NIO: handshake timeout — closing unauthenticated connection")
            context.close(promise: nil)
        }
        session.socket.onPrioritizedWrite = { [weak self, weak context] bytes, priority in
            guard let self, let context else { return false }
            return self.enqueueOutbound(bytes, priority: priority, context: context)
        }
        session.socket.onClose = { [weak context] in
            context?.eventLoop.execute {
                context?.close(promise: nil)
            }
        }
    }

    @discardableResult
    private func enqueueOutbound(
        _ bytes: [UInt8],
        priority: RDPSocket.WritePriority,
        context: ChannelHandlerContext
    ) -> Bool {
        guard !bytes.isEmpty else { return true }

        var droppedAudioBytes = 0
        var queuedBytes: Int?
        var accepted = true
        var closeForControlOverflow = false
        var droppedVideoBytes: Int?
        outboundLock.lock()
        switch priority {
        case .audio:
            guard bytes.count <= Self.maxQueuedAudioBytes else {
                outboundLock.unlock()
                return false
            }
            while pendingAudioWrites.byteCount + bytes.count > Self.maxQueuedAudioBytes,
                  let dropped = pendingAudioWrites.popFirst()
            {
                droppedAudioBytes += dropped.count
            }
            pendingAudioWrites.append(bytes)
        case .control:
            let controlBytes = pendingControlWrites.byteCount + bytes.count
            if controlBytes > Self.maxQueuedControlBytes {
                accepted = false
                closeForControlOverflow = true
            } else {
                pendingControlWrites.append(bytes)
                queuedBytes = pendingControlWrites.byteCount + pendingVideoWrites.byteCount
            }
        case .video:
            let videoLimit = session.videoOutboundQueueLimitBytes
            if bytes.count > Self.maxVideoWriteBytes || !pendingVideoWrites.isEmpty {
                accepted = false
                droppedVideoBytes = bytes.count
            } else {
                // A single encoded frame may exceed the time budget. It is still
                // safe to admit as one atomic item; the gate pauses the next frame.
                pendingVideoWrites.append(bytes)
                queuedBytes = pendingControlWrites.byteCount + pendingVideoWrites.byteCount
                if queuedBytes ?? 0 > videoLimit {
                    RDPLog.io.debug(
                        "NIO: admitted oversized video frame \(bytes.count)B " +
                        "above \(videoLimit)B time budget"
                    )
                }
            }
        }
        let shouldSchedule = accepted && !outboundDrainScheduled
        if shouldSchedule {
            outboundDrainScheduled = true
        }
        outboundLock.unlock()

        if let queuedBytes {
            session.setNIOOutboundQueueBytes(queuedBytes)
        }

        if droppedAudioBytes > 0 {
            RDPLog.io.debug("NIO: dropped \(droppedAudioBytes)B stale audio under TCP backpressure")
        }

        if let droppedVideoBytes {
            RDPLog.io.debug(
                "NIO: dropped video frame \(droppedVideoBytes)B — video queue is busy or frame is too large"
            )
        }

        if closeForControlOverflow {
            RDPLog.io.error(
                "NIO: control outbound queue exceeded \(Self.maxQueuedControlBytes)B — closing connection"
            )
            context.eventLoop.execute { [weak context] in
                context?.close(promise: nil)
            }
            return false
        }

        guard accepted else { return false }

        if context.eventLoop.inEventLoop {
            // Keep handshake writes synchronous: X.224 CC must be flushed before
            // the TLS handler is installed in the same channelRead turn.
            drainOutbound(context: context)
        } else if shouldSchedule {
            context.eventLoop.execute { [weak self, weak context] in
                guard let self, let context else { return }
                self.drainOutbound(context: context)
            }
        }
        return true
    }

    /// Drain audio first, then bounded control and video batches, and flush once. The byte
    /// and time limits keep graphics from monopolizing audio latency or the
    /// event loop while avoiding one flush per GFX fragment.
    private func drainOutbound(context: ChannelHandlerContext) {
        guard context.eventLoop.inEventLoop else { return }
        guard context.channel.isWritable else {
            outboundLock.lock()
            outboundDrainScheduled = false
            outboundLock.unlock()
            return
        }

        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ Self.drainTimeLimitNanoseconds
        var wroteBytes = 0
        var audioBytes = 0
        var controlBytes = 0
        var videoBytes = 0

        func write(_ bytes: [UInt8]) {
            var buffer = context.channel.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            context.write(NIOAny(buffer), promise: nil)
            wroteBytes += bytes.count
        }

        while DispatchTime.now().uptimeNanoseconds < deadline {
            outboundLock.lock()
            if context.channel.isWritable,
               !pendingAudioWrites.isEmpty,
               audioBytes < Self.audioBatchByteLimit
            {
                let next = pendingAudioWrites.popFirst()
                outboundLock.unlock()
                if let next {
                    write(next)
                    audioBytes += next.count
                }
                continue
            }
            if context.channel.isWritable, !pendingControlWrites.isEmpty,
               controlBytes < Self.controlBatchByteLimit
            {
                let next = pendingControlWrites.popFirst()
                outboundLock.unlock()
                if let next {
                    write(next)
                    controlBytes += next.count
                }
                continue
            }
            if context.channel.isWritable, !pendingVideoWrites.isEmpty,
               videoBytes < Self.videoBatchByteLimit
            {
                let next = pendingVideoWrites.popFirst()
                outboundLock.unlock()
                if let next {
                    write(next)
                    videoBytes += next.count
                }
                continue
            } else {
                outboundLock.unlock()

                break
            }
        }

        if wroteBytes > 0 {
            context.flush()
        }

        outboundLock.lock()
        let hasPending = !pendingAudioWrites.isEmpty
            || !pendingControlWrites.isEmpty
            || !pendingVideoWrites.isEmpty
        let queuedBytes = pendingControlWrites.byteCount + pendingVideoWrites.byteCount
        let shouldSchedule = hasPending && context.channel.isWritable
        outboundDrainScheduled = shouldSchedule
        outboundLock.unlock()
        session.setNIOOutboundQueueBytes(queuedBytes)
        if shouldSchedule {
            context.eventLoop.execute { [weak self, weak context] in
                guard let self, let context else { return }
                self.drainOutbound(context: context)
            }
        }
    }

    public func channelWritabilityChanged(context: ChannelHandlerContext) {
        // Session owns the synchronized transport state and GFX admission gate.
        session.setChannelWritable(context.channel.isWritable)
        if context.channel.isWritable {
            drainOutbound(context: context)
        }
        context.fireChannelWritabilityChanged()
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        guard let bytes = buf.readBytes(length: buf.readableBytes) else { return }
        // Process on this event-loop turn so X.224 CC is written cleartext first.
        session.receive(bytes)
        if session.phase == .active {
            handshakeTimeoutTask?.cancel()
            handshakeTimeoutTask = nil
        }
        if !sslAdded, session.wantsTLS, session.phase == .tls {
            // ClientHello may already sit in session.buffer (same TCP segment as CR,
            // or raced before NIOSSL install). Drain + reinject into SSL or the
            // handshake fails with UNSUPPORTED_PROTOCOL and the client hangs on
            // "配置远程电脑".
            let leftover = session.takeTLSLeftover()
            promoteToTLS(context: context, reinject: leftover)
        }
    }

    private func promoteToTLS(context: ChannelHandlerContext, reinject: [UInt8]) {
        guard !sslAdded else { return }
        sslAdded = true
        RDPLog.io.info("X.224 CC sent + TLS handler installed atomically")
        RDPLog.io.info("Sent X.224 Connection Confirm (atomic with TLS upgrade)")
        RDPLog.io.debug("Installing NIOSSLHandler for RDP TLS (after X.224 CC)")
        context.flush()
        let handler = NIOSSLServerHandler(context: sslContext)
        do {
            // Sync on this event-loop turn — must be installed before we return so the
            // next read hits SSL, and before we reinject any leftover ClientHello.
            try context.pipeline.syncOperations.addHandler(handler, position: .first)
            if !reinject.isEmpty {
                RDPLog.io.debug("TLS: reinjecting \(reinject.count)B ClientHello leftover into NIOSSL")
                var pending = context.channel.allocator.buffer(capacity: reinject.count)
                pending.writeBytes(reinject)
                context.pipeline.fireChannelRead(pending)
                context.pipeline.fireChannelReadComplete()
            }
        } catch {
            RDPLog.io.error("TLS install failed: \(error)")
            RDPLog.io.error("NIOTransport required for TLS")
            context.close(promise: nil)
        }
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let evt = event as? TLSUserEvent, case .handshakeCompleted = evt {
            RDPLog.io.info("TLS handshake completed (NIO SSL)")
            session.notifyTLSCompleted()
        }
        context.fireUserInboundEventTriggered(event)
    }

    public func channelInactive(context: ChannelHandlerContext) {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        outboundLock.lock()
        pendingAudioWrites.removeAll()
        pendingControlWrites.removeAll()
        pendingVideoWrites.removeAll()
        outboundDrainScheduled = false
        outboundLock.unlock()
        session.setNIOOutboundQueueBytes(0)
        RDPLog.io.info("Client disconnected")
        RDPLog.io.debug("NIO: channelInactive / peer closed")
        session.terminate()
        session.sessionManager?.unregisterSession(session)
        context.fireChannelInactive()
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        RDPLog.io.error("NIO: channel error \(error)")
        context.close(promise: nil)
    }
}
