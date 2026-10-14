import Foundation
import NIOCore

/// A native NIO channel over the ordered UDP2 stream. This lets NIOSSL use its normal
/// TLS implementation without a second crypto stack or a simulated test channel.
final class RDPUDPStream: Channel, ChannelCore, @unchecked Sendable {
    let allocator = ByteBufferAllocator()
    let eventLoop: EventLoop
    let parent: Channel?
    let localAddress: SocketAddress?
    let remoteAddress: SocketAddress?
    private let closePromise: EventLoopPromise<Void>
    private lazy var channelPipeline = ChannelPipeline(channel: self)
    private let stateLock = NSLock()
    private var active = false
    private var writable = true
    private var closed = false
    private var nextWrite = 0
    private var promises: [Int: EventLoopPromise<Void>] = [:]

    var onWrite: ((ByteBuffer, RDPUDP2Connection.Completion?) throws -> Void)?
    var onFlush: (() -> Void)?
    var onClosed: ((Error) -> Void)?

    init(parent: Channel, remoteAddress: SocketAddress) {
        self.parent = parent
        self.eventLoop = parent.eventLoop
        self.localAddress = parent.localAddress
        self.remoteAddress = remoteAddress
        closePromise = parent.eventLoop.makePromise(of: Void.self)
    }

    var closeFuture: EventLoopFuture<Void> { closePromise.futureResult }
    var pipeline: ChannelPipeline { channelPipeline }
    var _channelCore: ChannelCore { self }
    var isActive: Bool { stateLock.withLock { active } }
    var isWritable: Bool { stateLock.withLock { writable && !closed } }

    func receive(_ bytes: [UInt8]) {
        eventLoop.preconditionInEventLoop()
        guard isActive else { return }
        pipeline.fireChannelRead(NIOAny(ByteBuffer(bytes: bytes)))
        pipeline.fireChannelReadComplete()
    }

    func setWritable(_ value: Bool) {
        eventLoop.preconditionInEventLoop()
        let changed = stateLock.withLock { () -> Bool in
            guard writable != value else { return false }
            writable = value
            return true
        }
        if changed { pipeline.fireChannelWritabilityChanged() }
    }

    func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> EventLoopFuture<Void> {
        if option is ChannelOptions.Types.AutoReadOption, value as? Bool == true {
            return eventLoop.makeSucceededVoidFuture()
        }
        if option is ChannelOptions.Types.AllowRemoteHalfClosureOption, value as? Bool == false {
            return eventLoop.makeSucceededVoidFuture()
        }
        return eventLoop.makeFailedFuture(ChannelError.operationUnsupported)
    }

    func getOption<Option: ChannelOption>(_ option: Option) -> EventLoopFuture<Option.Value> {
        if option is ChannelOptions.Types.AutoReadOption {
            return eventLoop.makeSucceededFuture(true as! Option.Value)
        }
        if option is ChannelOptions.Types.AllowRemoteHalfClosureOption {
            return eventLoop.makeSucceededFuture(false as! Option.Value)
        }
        return eventLoop.makeFailedFuture(ChannelError.operationUnsupported)
    }

    func register(promise: EventLoopPromise<Void>?) { pipeline.register(promise: promise) }
    func bind(to address: SocketAddress, promise: EventLoopPromise<Void>?) { pipeline.bind(to: address, promise: promise) }
    func connect(to address: SocketAddress, promise: EventLoopPromise<Void>?) { pipeline.connect(to: address, promise: promise) }
    func write(_ data: NIOAny, promise: EventLoopPromise<Void>?) { pipeline.write(data, promise: promise) }
    func flush() { pipeline.flush() }
    func read() { pipeline.read() }
    func close(mode: CloseMode, promise: EventLoopPromise<Void>?) { pipeline.close(mode: mode, promise: promise) }
    func triggerUserOutboundEvent(_ event: Any & Sendable, promise: EventLoopPromise<Void>?) {
        pipeline.triggerUserOutboundEvent(event, promise: promise)
    }

    func localAddress0() throws -> SocketAddress {
        guard let localAddress else { throw ChannelError.operationUnsupported }; return localAddress
    }
    func remoteAddress0() throws -> SocketAddress {
        guard let remoteAddress else { throw ChannelError.operationUnsupported }; return remoteAddress
    }
    func register0(promise: EventLoopPromise<Void>?) { registerAlreadyConfigured0(promise: promise) }
    func registerAlreadyConfigured0(promise: EventLoopPromise<Void>?) {
        eventLoop.preconditionInEventLoop()
        stateLock.withLock { active = true }
        pipeline.fireChannelRegistered()
        pipeline.fireChannelActive()
        promise?.succeed(())
    }
    func bind0(to address: SocketAddress, promise: EventLoopPromise<Void>?) { promise?.fail(ChannelError.operationUnsupported) }
    func connect0(to address: SocketAddress, promise: EventLoopPromise<Void>?) { promise?.fail(ChannelError.operationUnsupported) }
    func read0() {} // UDP2 delivers ordered bytes as datagrams arrive (autoRead).

    func write0(_ data: NIOAny, promise: EventLoopPromise<Void>?) {
        eventLoop.preconditionInEventLoop()
        guard isActive, let onWrite else { promise?.fail(ChannelError.ioOnClosedChannel); return }
        let bytes: ByteBuffer = unwrapData(data)
        let id = nextWrite
        nextWrite += 1
        if let promise { promises[id] = promise }
        do {
            try onWrite(bytes) { [weak self] in self?.promises.removeValue(forKey: id)?.succeed(()) }
        } catch {
            promises.removeValue(forKey: id)?.fail(error)
            close0(error: error, mode: .all, promise: nil)
        }
    }
    func flush0() { eventLoop.preconditionInEventLoop(); if isActive { onFlush?() } }
    func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?) {
        promise?.fail(ChannelError.operationUnsupported)
    }
    func channelRead0(_ data: NIOAny) { errorCaught0(error: RDPUDPError.malformedPacket) }
    func errorCaught0(error: Error) { close0(error: error, mode: .all, promise: nil) }

    func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        eventLoop.preconditionInEventLoop()
        let wasOpen = stateLock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true; active = false
            return true
        }
        guard wasOpen else { promise?.fail(ChannelError.alreadyClosed); return }
        for p in promises.values { p.fail(error) }
        promises.removeAll()
        onClosed?(error)
        onWrite = nil; onFlush = nil; onClosed = nil
        pipeline.fireChannelInactive()
        pipeline.fireChannelUnregistered()
        promise?.succeed(())
        eventLoop.execute { [self] in
            removeHandlers(pipeline: pipeline)
            closePromise.succeed(())
        }
    }
}
