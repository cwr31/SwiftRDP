import Foundation
import Darwin
import NIO
import NIOSSL
import NIOTLS
import Security

/// Authenticated handle for one reliable UDP2 tunnel. Session callbacks run on the
/// main TCP event loop; transport state and TLS run on the UDP listener's event loop.
final class MultitransportTunnel: @unchecked Sendable {
    struct State: Sendable {
        var queuedBytes = 0
        var framesFull = false
        var rttNanoseconds: Double = 0
        var rttMeasuredAt: UInt64 = 0
    }
    struct Batch: Sendable {
        let messages: [[UInt8]]
        let bytes: Int
        let video: Bool
        let onWritten: RDPSocket.WriteCompletion?
    }
    let id = UUID()
    let requestID: UInt32
    let cookie: [UInt8]
    let cookieHash: [UInt8]
    let mainLoop: EventLoop
    private let listener: MultitransportListener
    private let lock = NSLock()
    private weak var peer: UDPTransportPeer?
    private var closed = false
    private var ready = false
    private var frames = 0
    private var applicationBytes = 0
    private var lastPublished = State()
    private var lastPublishedAt: UInt64 = 0
    private let onReady: @Sendable () -> Void
    private let onData: @Sendable ([UInt8]) -> Void
    private let onState: @Sendable (State) -> Void
    private let onFailure: @Sendable () -> Void

    init(listener: MultitransportListener, mainLoop: EventLoop,
         onReady: @escaping @Sendable () -> Void,
         onData: @escaping @Sendable ([UInt8]) -> Void,
         onState: @escaping @Sendable (State) -> Void,
         onFailure: @escaping @Sendable () -> Void) throws {
        var random = [UInt8](repeating: 0, count: 20)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw RDPUDPError.unauthenticatedTunnel
        }
        requestID = UInt32(random[0]) | UInt32(random[1]) << 8 | UInt32(random[2]) << 16 | UInt32(random[3]) << 24
        cookie = Array(random[4...])
        cookieHash = RDPUDPSyn.encodeCookieHash(cookie)
        self.listener = listener
        self.mainLoop = mainLoop
        self.onReady = onReady; self.onData = onData; self.onState = onState; self.onFailure = onFailure
    }

    var isReady: Bool { lock.withLock { ready && !closed } }
    var initiatePDU: [UInt8] { MultitransportPDU.initiate(requestID: requestID, cookie: cookie) }

    fileprivate func attach(_ peer: UDPTransportPeer) -> Bool {
        lock.withLock {
            guard self.peer == nil, !closed else { return false }
            self.peer = peer
            return true
        }
    }

    fileprivate func authenticated() {
        let notify = lock.withLock { () -> Bool in
            guard !closed, !ready else { return false }
            ready = true
            return true
        }
        if notify { mainLoop.execute(onReady) }
    }

    @discardableResult
    func send(_ messages: [[UInt8]], priority: RDPSocket.WritePriority,
              onWritten: RDPSocket.WriteCompletion?) -> Int? {
        let bytes = messages.reduce(0) { $0 + $1.count + 4 }
        let video = priority == .video
        let target = lock.withLock { () -> UDPTransportPeer? in
            guard ready, !closed, let peer, bytes > 0,
                  messages.allSatisfy({ !$0.isEmpty && $0.count <= 65_535 }),
                  bytes <= 16 * 1024 * 1024,
                  applicationBytes + bytes <= 32 * 1024 * 1024,
                  !video || frames < 2 else { return nil }
            applicationBytes += bytes
            if video { frames += 1 }
            return peer
        }
        guard let target else { return nil }
        let batch = Batch(messages: messages, bytes: bytes, video: video, onWritten: onWritten)
        target.eventLoop.execute { target.enqueue(batch) }
        return bytes
    }

    /// Called only when the Soft-Sync request has been written behind all old TCP GFX.
    func enableOutbound() { perform { $0.enableOutbound() } }
    /// Called after the main connection has consumed the client's Soft-Sync response.
    func enableInbound() { perform { $0.enableInbound() } }
    func setTargetBitrate(_ bitrate: Int) { perform { $0.setTargetBitrate(bitrate) } }

    private func perform(_ body: @escaping @Sendable (UDPTransportPeer) -> Void) {
        let peer = lock.withLock { closed ? nil : self.peer }
        if let peer { peer.eventLoop.execute { body(peer) } }
    }

    func close() {
        let notify = lock.withLock { () -> Bool in
            guard !closed else { return false }; closed = true; return true
        }
        if notify { listener.remove(self) }
    }

    fileprivate func failed() {
        let notify = lock.withLock { () -> Bool in
            guard !closed else { return false }; closed = true; return true
        }
        if notify { mainLoop.execute(onFailure) }
    }

    fileprivate func written(_ batch: Batch) {
        lock.withLock {
            applicationBytes -= batch.bytes
            if batch.video { frames -= 1 }
        }
        batch.onWritten?(DispatchTime.now().uptimeNanoseconds)
    }

    fileprivate func deliver(_ bytes: [UInt8]) { mainLoop.execute { [onData] in onData(bytes) } }

    fileprivate func publish(engine: RDPUDP2Connection, unsentApplication: Int, now: UInt64) -> UInt64? {
        let state = lock.withLock {
            State(queuedBytes: engine.queuedBytes + unsentApplication,
                  framesFull: frames >= 2, rttNanoseconds: engine.smoothedRTTNanoseconds,
                  rttMeasuredAt: engine.rttMeasuredAt)
        }
        guard state.queuedBytes != lastPublished.queuedBytes || state.framesFull != lastPublished.framesFull
                || state.rttMeasuredAt != lastPublished.rttMeasuredAt else { return nil }
        // Queue transitions wake encoding immediately; routine measurements are bounded to 50Hz.
        guard now - lastPublishedAt >= 20_000_000 || state.framesFull != lastPublished.framesFull
                || (state.queuedBytes == 0 && lastPublished.queuedBytes != 0) else {
            return lastPublishedAt + 20_000_000
        }
        lastPublished = state; lastPublishedAt = now
        mainLoop.execute { [onState] in onState(state) }
        return nil
    }
}

final class MultitransportListener: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    private let sslContext: NIOSSLContext
    private var channel: Channel?
    private var requests: [[UInt8]: MultitransportTunnel] = [:]
    private var deadlines: [UUID: Scheduled<Void>] = [:]
    private var peers: [SocketAddress: UDPTransportPeer] = [:]
    private var loggedHandshakeRejection = false

    init(sslContext: NIOSSLContext) { self.sslContext = sslContext }
    func handlerAdded(context: ChannelHandlerContext) { channel = context.channel }

    func prepare(mainLoop: EventLoop, onReady: @escaping @Sendable () -> Void,
                 onData: @escaping @Sendable ([UInt8]) -> Void,
                 onState: @escaping @Sendable (MultitransportTunnel.State) -> Void,
                 onFailure: @escaping @Sendable () -> Void) throws -> MultitransportTunnel {
        let tunnel = try MultitransportTunnel(listener: self, mainLoop: mainLoop, onReady: onReady,
                                             onData: onData, onState: onState, onFailure: onFailure)
        guard let channel else { throw RDPUDPError.tunnelClosed }
        channel.eventLoop.execute { [self] in
            guard channel.isActive, requests.count < 4 else { tunnel.failed(); return }
            requests[tunnel.cookieHash] = tunnel
            loggedHandshakeRejection = false
            deadlines[tunnel.id] = channel.eventLoop.scheduleTask(in: .seconds(10)) { [weak self] in
                guard let self else { return }
                deadlines.removeValue(forKey: tunnel.id)
                if !tunnel.isReady {
                    RDPLog.io.notice("UDP2 bootstrap timed out before tunnel authentication")
                    expire(tunnel)
                }
            }
        }
        return tunnel
    }

    func remove(_ tunnel: MultitransportTunnel) {
        channel?.eventLoop.execute { [weak self] in self?.expire(tunnel) }
    }

    private func expire(_ tunnel: MultitransportTunnel) {
        requests.removeValue(forKey: tunnel.cookieHash)
        deadlines.removeValue(forKey: tunnel.id)?.cancel()
        for peer in peers.values.filter({ $0.tunnel.id == tunnel.id }) { peer.close() }
        tunnel.failed()
    }

    fileprivate func peerClosed(_ peer: UDPTransportPeer) {
        peers.removeValue(forKey: peer.address)
        requests.removeValue(forKey: peer.tunnel.cookieHash)
        deadlines.removeValue(forKey: peer.tunnel.id)?.cancel()
        peer.tunnel.failed()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        // Bound decoding/allocation before examining an unauthenticated datagram.
        guard (8...1232).contains(envelope.data.readableBytes) else { return }
        let bytes = Array(envelope.data.readableBytesView)
        if let peer = peers[envelope.remoteAddress] { peer.receive(bytes); return }
        guard !requests.isEmpty else { return }
        do {
            let syn = try RDPUDPSyn.parse(bytes)
            guard let tunnel = requests[syn.cookieHash],
                  MultitransportPDU.constantTimeEqual(syn.cookieHash, tunnel.cookieHash) else {
                noteHandshakeRejection("SYN cookie hash does not match a pending request")
                return
            }
            guard let packetInfo = envelope.metadata?.packetInfo else {
                noteHandshakeRejection("SYN has no local address/interface metadata")
                return
            }
            let peer = try UDPTransportPeer(listener: self, channel: context.channel,
                                            address: envelope.remoteAddress, syn: syn,
                                            tunnel: tunnel, sslContext: sslContext, packetInfo: packetInfo)
            guard tunnel.attach(peer) else { return }
            peers[envelope.remoteAddress] = peer
            peer.open()
        } catch {
            noteHandshakeRejection(String(describing: error))
        }
    }

    /// One rejection per negotiation, with no cookies or payload bytes in the log.
    private func noteHandshakeRejection(_ reason: String) {
        guard !loggedHandshakeRejection else { return }
        loggedHandshakeRejection = true
        RDPLog.io.notice("UDP2 SYN rejected: \(reason)")
    }

    func channelInactive(context: ChannelHandlerContext) {
        for peer in Array(peers.values) { peer.close() }
        for request in Array(requests.values) { expire(request) }
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        RDPLog.io.error("UDP listener error: \(error)")
        context.close(promise: nil)
    }
}

fileprivate final class UDPTransportPeer: @unchecked Sendable {
    let address: SocketAddress
    let tunnel: MultitransportTunnel
    let eventLoop: EventLoop
    private let listener: MultitransportListener
    private var channel: Channel?
    private let localAddress: SocketAddress
    private let interfaceIndex: Int
    private let syn: RDPUDPSyn
    private let sslContext: NIOSSLContext
    private let synAck: [UInt8]
    private var synAttempts = 0
    private var stream: RDPUDPStream?
    private var engine: RDPUDP2Connection?
    private var timer: Scheduled<Void>?
    private var closed = false
    private var pumping = false
    private var loggedInvalidHandshake = false
    private var loggedInvalidData = false
    private var outboundEnabled = false
    private var inboundEnabled = false
    private var queuedApplication = CircularBuffer<MultitransportTunnel.Batch>()
    private var unsentApplicationBytes = 0
    private var heldInbound = CircularBuffer<[UInt8]>()
    private var heldInboundBytes = 0

    init(listener: MultitransportListener, channel: Channel, address: SocketAddress,
         syn: RDPUDPSyn, tunnel: MultitransportTunnel, sslContext: NIOSSLContext,
         packetInfo: NIOPacketInfo) throws {
        var sequence: UInt32 = 0
        guard SecRandomCopyBytes(kSecRandomDefault, 4, &sequence) == errSecSuccess else {
            throw RDPUDPError.unauthenticatedTunnel
        }
        guard let port = channel.localAddress?.port, packetInfo.interfaceIndex > 0 else {
            throw RDPUDPError.malformedPacket
        }
        var localAddress = packetInfo.destinationAddress
        localAddress.port = port
        self.localAddress = localAddress
        interfaceIndex = packetInfo.interfaceIndex
        self.listener = listener; self.eventLoop = channel.eventLoop
        self.address = address; self.syn = syn; self.tunnel = tunnel; self.sslContext = sslContext
        synAck = syn.acknowledgement(serverSequence: sequence, receiveWindow: UInt16(RDPUDP2Connection.window))
    }

    /// Scope a connected socket to the actual SYN ingress path, including VPN interfaces.
    func open() {
        let option = ChannelOptions.Types.SocketOption(
            level: localAddress.protocol == .inet6 ? .ipv6 : .ip,
            name: .init(rawValue: localAddress.protocol == .inet6 ? IPV6_BOUND_IF : IP_BOUND_IF))
        DatagramBootstrap(group: eventLoop)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.socketOption(.init(rawValue: SO_REUSEPORT)), value: 1)
            .channelOption(option, value: Int32(interfaceIndex))
            .channelOption(ChannelOptions.socketOption(.so_sndbuf), value: 256 * 1024)
            .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 2048))
            .channelInitializer { $0.pipeline.addHandler(DatagramHandler(peer: self)) }
            .bind(to: localAddress)
            .flatMap { channel in
                channel.connect(to: self.address).map { channel }.flatMapError { error in
                    channel.close().flatMapThrowing { throw error }
                }
            }
            .whenComplete { [weak self] result in
                switch result {
                case .success(let channel):
                    guard let self, !closed else { channel.close(promise: nil); return }
                    self.channel = channel
                    RDPLog.io.notice("UDP2 SYN accepted; reply interface=\(interfaceIndex) local=\(localAddress)")
                    start()
                case .failure(let error):
                    RDPLog.io.notice("UDP2 ingress socket failed: \(error)")
                    self?.close()
                }
            }
    }

    private final class DatagramHandler: ChannelInboundHandler {
        typealias InboundIn = AddressedEnvelope<ByteBuffer>
        private weak var peer: UDPTransportPeer?
        init(peer: UDPTransportPeer) { self.peer = peer }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let envelope = unwrapInboundIn(data)
            guard envelope.remoteAddress == peer?.address,
                  (8...1232).contains(envelope.data.readableBytes) else { return }
            peer?.receive(Array(envelope.data.readableBytesView))
        }
        func channelInactive(context: ChannelHandlerContext) {
            peer?.close()
            context.fireChannelInactive()
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) {
            RDPLog.io.notice("UDP2 socket error: \(error)")
            peer?.close()
        }
    }

    func start() {
        guard !closed else { return }
        write(synAck)
        synAttempts += 1
        timer = eventLoop.scheduleTask(in: .milliseconds(300 * (1 << min(synAttempts - 1, 3)))) { [weak self] in
            guard let self else { return }
            if synAttempts >= 5 { close() } else { start() }
        }
    }

    func receive(_ bytes: [UInt8]) {
        guard !closed else { return }
        if bytes.starts(with: [0xFF, 0xFF, 0xFF, 0xFF]),
           let repeated = try? RDPUDPSyn.parse(bytes), repeated.initialSequence == syn.initialSequence {
            if engine == nil { write(synAck) }
            return
        }
        do {
            let packet = try RDPUDP2Packet.parse(bytes)
            if engine == nil {
                guard !packet.dummy, let data = packet.data else {
                    rejectHandshake("expected UDP2 DATA; bytes=\(bytes.count)")
                    return
                }
                // UDP2 starts a new sequence space; SYN ISNs belong only to initialization.
                let receiveSequence = UInt64(packet.ackOfAcks ?? data.sequence)
                try establish(receiveSequence: receiveSequence, peerWindow: 1 << packet.logWindow)
                RDPLog.io.notice("UDP2 data phase started: send=100 receiveBase=\(receiveSequence) firstData=\(data.sequence)")
            }
            for ordered in try engine!.receive(packet, now: DispatchTime.now().uptimeNanoseconds) {
                stream?.receive(ordered)
            }
            pump()
        } catch {
            // Invalid unauthenticated datagrams cannot tear down an established TLS tunnel.
            switch error {
            case is RDPUDP2Packet.ParseError, RDPUDPError.malformedPacket:
                if engine == nil {
                    rejectHandshake("bytes=\(bytes.count) \(error)")
                    return
                }
                if !loggedInvalidData {
                    loggedInvalidData = true
                    RDPLog.io.notice("UDP2 data packet rejected: bytes=\(bytes.count) \(error)")
                }
                return
            default:
                RDPLog.io.notice("UDP2 receive failed: \(error)")
                close()
            }
        }
    }

    private func rejectHandshake(_ reason: String) {
        guard !loggedInvalidHandshake else { return }
        loggedInvalidHandshake = true
        RDPLog.io.notice("UDP2 bootstrap packet rejected: \(reason)")
    }

    private func establish(receiveSequence: UInt64, peerWindow: Int) throws {
        guard let channel else { throw RDPUDPError.tunnelClosed }
        timer?.cancel()
        engine = RDPUDP2Connection(initialReceiveSequence: receiveSequence,
                                   mtu: Int(min(syn.upstreamMTU, syn.downstreamMTU)),
                                   peerWindow: peerWindow, now: DispatchTime.now().uptimeNanoseconds)
        let stream = RDPUDPStream(parent: channel, remoteAddress: address)
        self.stream = stream
        stream.onWrite = { [weak self] bytes, onSent in try self?.engine?.enqueue(bytes, onSent: onSent) }
        stream.onFlush = { [weak self] in self?.pump() }
        stream.onClosed = { [weak self] error in
            guard let self, !closed else { return }
            RDPLog.io.notice("UDP2 TLS stream closed: \(error)")
            close()
        }
        try stream.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
        try stream.pipeline.syncOperations.addHandler(TunnelHandler(peer: self))
        stream.registerAlreadyConfigured0(promise: nil)
        pump()
    }

    func setTargetBitrate(_ bitrate: Int) { engine?.setTargetBitrate(bitrate); pump() }
    func enqueue(_ batch: MultitransportTunnel.Batch) {
        guard !closed else { return }
        queuedApplication.append(batch)
        unsentApplicationBytes += batch.bytes
        if outboundEnabled { drainApplication() }
        pump()
    }
    func enableOutbound() { outboundEnabled = true; drainApplication(); pump() }
    func enableInbound() {
        inboundEnabled = true
        while let data = heldInbound.popFirst() { tunnel.deliver(data) }
        heldInboundBytes = 0
    }

    private func drainApplication() {
        guard let stream, !closed else { return }
        while let batch = queuedApplication.popFirst() {
            unsentApplicationBytes -= batch.bytes
            let done = eventLoop.makePromise(of: Void.self)
            done.futureResult.whenSuccess { [weak self] in
                guard let self, !closed else { return }
                tunnel.written(batch)
                pump()
            }
            done.futureResult.whenFailure { [weak self] _ in self?.close() }
            for (index, message) in batch.messages.enumerated() {
                let bytes = MultitransportPDU.TunnelMessage(action: .data, payload: message).encode()
                stream.write(ByteBuffer(bytes: bytes), promise: index == batch.messages.count - 1 ? done : nil)
            }
            stream.flush()
        }
    }

    fileprivate func handle(_ message: MultitransportPDU.TunnelMessage, context: ChannelHandlerContext) throws {
        switch message.action {
        case .createRequest:
            guard !tunnel.isReady, message.subheaders.isEmpty,
                  MultitransportPDU.authenticates(message.payload, requestID: tunnel.requestID, cookie: tunnel.cookie)
            else { throw RDPUDPError.unauthenticatedTunnel }
            let response = MultitransportPDU.TunnelMessage(action: .createResponse, payload: [0, 0, 0, 0]).encode()
            context.writeAndFlush(NIOAny(ByteBuffer(bytes: response)), promise: nil)
            tunnel.authenticated()
            RDPLog.io.info("UDP2 TLS tunnel authenticated; waiting for Soft-Sync")
        case .data:
            guard tunnel.isReady else { throw RDPUDPError.unauthenticatedTunnel }
            // Network autodetect subheaders are optional; no measurement is initiated on this tunnel.
            guard !message.payload.isEmpty else { return }
            if inboundEnabled { tunnel.deliver(message.payload) }
            else {
                guard heldInboundBytes + message.payload.count <= 1024 * 1024 else { throw RDPUDPError.bufferOverflow }
                heldInboundBytes += message.payload.count
                heldInbound.append(message.payload)
            }
        case .createResponse: throw RDPUDPError.malformedPacket
        }
    }

    private func pump() {
        guard !closed, !pumping, let engine else { return }
        pumping = true
        defer { pumping = false }
        timer?.cancel()
        let now = DispatchTime.now().uptimeNanoseconds
        do {
            let packets = try engine.transmit(now: now)
            for packet in packets { write(packet.bytes, onSent: packet.onSent, flush: false) }
            if !packets.isEmpty { channel?.flush() }
            guard !closed else { return }
            stream?.setWritable(engine.queuedBytes < 256 * 1024)
            let statisticsDeadline = tunnel.publish(engine: engine, unsentApplication: unsentApplicationBytes, now: now)
            if let deadline = [engine.nextDeadline(now: now), statisticsDeadline].compactMap({ $0 }).min() {
                timer = eventLoop.scheduleTask(deadline: NIODeadline.uptimeNanoseconds(deadline)) { [weak self] in self?.pump() }
            }
        } catch { close() }
    }

    private func write(_ bytes: [UInt8], onSent: RDPUDP2Connection.Completion? = nil, flush: Bool = true) {
        guard let channel, !closed else { return }
        let promise = eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenSuccess { onSent?() }
        promise.futureResult.whenFailure { [weak self] error in
            RDPLog.io.notice("UDP2 socket write failed: \(error)")
            self?.close()
        }
        channel.write(AddressedEnvelope(remoteAddress: address, data: ByteBuffer(bytes: bytes)), promise: promise)
        if flush { channel.flush() }
    }

    func close() {
        guard !closed else { return }
        closed = true
        timer?.cancel(); timer = nil
        stream?.close0(error: RDPUDPError.tunnelClosed, mode: .all, promise: nil)
        stream = nil; engine = nil
        channel?.close(promise: nil)
        channel = nil
        queuedApplication.removeAll(); heldInbound.removeAll()
        listener.peerClosed(self)
    }

    private final class TunnelHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        private weak var peer: UDPTransportPeer?
        private var buffer = ByteBuffer()
        init(peer: UDPTransportPeer) { self.peer = peer }
        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if let tls = event as? TLSUserEvent, case .handshakeCompleted = tls {
                RDPLog.io.notice("UDP2 TLS handshake completed")
            }
            context.fireUserInboundEventTriggered(event)
        }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var bytes = unwrapInboundIn(data)
            guard buffer.readableBytes + bytes.readableBytes <= 128 * 1024 else { peer?.close(); return }
            buffer.writeBuffer(&bytes)
            do {
                while let message = try MultitransportPDU.TunnelMessage.read(from: &buffer) {
                    try peer?.handle(message, context: context)
                }
                if buffer.readerIndex > 65_535 { buffer.discardReadBytes() }
            } catch {
                RDPLog.io.notice("UDP2 tunnel message rejected: \(error)")
                peer?.close()
            }
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) {
            RDPLog.io.notice("UDP2 TLS error: \(error)")
            peer?.close()
        }
    }
}
