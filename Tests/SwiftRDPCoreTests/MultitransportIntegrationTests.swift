import Darwin
import Foundation
import NIO
import NIOSSL
import NIOTLS
import XCTest
@testable import SwiftRDPCore

final class MultitransportIntegrationTests: XCTestCase {
    func testIndependentIronRDPClient() async throws {
        guard let clientPath = ProcessInfo.processInfo.environment["SWIFTRDP_IRONRDP_INTEROP_CLIENT"] else {
            throw XCTSkip("Run scripts/verify-multitransport-interop.sh for the independent IronRDP client")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("udp2-interop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let material = try CertStore.ensure(certsDirectory: directory, commonName: "localhost")
        var tls = TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate(material.certificate)],
                                                            privateKey: .privateKey(material.privateKey))
        tls.minimumTLSVersion = .tlsv12; tls.maximumTLSVersion = .tlsv12
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let listener = MultitransportListener(sslContext: try NIOSSLContext(configuration: tls))
        let server = try await DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.socketOption(.init(rawValue: SO_REUSEPORT)), value: 1)
            .channelOption(ChannelOptions.receivePacketInfo, value: true)
            .channelInitializer { $0.pipeline.addHandler(listener) }
            .bind(host: "127.0.0.1", port: 0).get()
        let holder = IntegrationTunnelHolder()
        let authenticated = expectation(description: "Independent TLS client authenticated")
        let received = expectation(description: "Independent client completed 40 messages")
        received.expectedFulfillmentCount = 40
        let tunnel = try listener.prepare(mainLoop: group.next(), onReady: {
            holder.value?.enableOutbound(); holder.value?.enableInbound(); authenticated.fulfill()
        }, onData: { bytes in
            XCTAssertEqual(bytes.count, 60_000)
            XCTAssertNotNil(holder.value?.send([bytes], priority: .graphicsControl, onWritten: nil))
            received.fulfill()
        }, onState: { _ in }, onFailure: { })
        holder.value = tunnel
        let configuration: [String: Any] = [
            "server": "127.0.0.1:\(server.localAddress!.port!)", "requestID": tunnel.requestID,
            "cookie": tunnel.cookie, "certificateDER": try material.certificate.toDERBytes(),
        ]
        let path = directory.appendingPathComponent("client.json")
        try JSONSerialization.data(withJSONObject: configuration).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: clientPath)
        process.arguments = [path.path]
        process.standardOutput = output; process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 0, log)
            await fulfillment(of: [authenticated, received], timeout: 1)
        } catch {
            tunnel.close(); try? await server.close().get(); try? await group.shutdownGracefully()
            throw error
        }
        tunnel.close()
        try await server.close().get()
        try await group.shutdownGracefully()
    }

    func testRealUDPTLSBindingSoftSyncGatesAndAtomicFrames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("udp2-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let material = try CertStore.ensure(certsDirectory: directory, commonName: "localhost")
        var serverTLS = TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate(material.certificate)],
                                                                  privateKey: .privateKey(material.privateKey))
        serverTLS.minimumTLSVersion = .tlsv12; serverTLS.maximumTLSVersion = .tlsv12
        var clientTLS = TLSConfiguration.makeClientConfiguration()
        clientTLS.minimumTLSVersion = .tlsv12; clientTLS.maximumTLSVersion = .tlsv12
        clientTLS.trustRoots = .certificates([material.certificate])
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let listener = MultitransportListener(sslContext: try NIOSSLContext(configuration: serverTLS))
        let server = try await DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.socketOption(.init(rawValue: SO_REUSEPORT)), value: 1)
            .channelOption(ChannelOptions.receivePacketInfo, value: true)
            .channelInitializer { $0.pipeline.addHandler(listener) }
            .bind(host: "127.0.0.1", port: 0).get()
        let authenticated = expectation(description: "Server authenticated main-connection cookie inside TLS")
        let clientReady = expectation(description: "Client received TunnelCreateResponse")
        let premature = expectation(description: "No application data before Soft-Sync")
        premature.isInverted = true
        let delivered = expectation(description: "Application data after client Soft-Sync")
        let frames = expectation(description: "Two complete graphics frames after TCP flush")
        frames.expectedFulfillmentCount = 2
        let wrapGroups = (0..<8).map { group in
            let completed = expectation(description: "TLS remains valid through reliable channel wrap, batch \(group)")
            completed.expectedFulfillmentCount = 2
            return completed
        }
        let flushed = expectation(description: "Both frame completions reflect actual UDP socket writes")
        flushed.expectedFulfillmentCount = 2
        let gate = IntegrationGate()
        let graphicsReceiver = IntegrationDVCReceiver { bytes, index in
            XCTAssertEqual(bytes.count, index < 2 ? 240_000 : 6_000_000)
            XCTAssertTrue(bytes.allSatisfy { $0 == 0x5A })
            if index < 2 { frames.fulfill() }
            else if index < 18 { wrapGroups[(index - 2) / 2].fulfill() }
            else { XCTFail("Unexpected extra graphics frame") }
        }
        let tunnel = try listener.prepare(mainLoop: group.next(), onReady: { authenticated.fulfill() },
            onData: { bytes in
                if !gate.isOpen { premature.fulfill() }
                XCTAssertEqual(bytes, Array("client ACK".utf8))
                delivered.fulfill()
            }, onState: { _ in }, onFailure: { })
        let client = IntegrationUDPClient(server: server.localAddress!, tunnel: tunnel,
                                          ssl: try NIOSSLContext(configuration: clientTLS),
                                          expectedCertificate: material.certificate,
                                          connected: { clientReady.fulfill() }, received: { bytes in
            if !gate.isOpen { premature.fulfill() }
            graphicsReceiver.receive(bytes)
        })
        let clientChannel = try await DatagramBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(client) }
            .bind(host: "127.0.0.1", port: 0).get()
        do {
            await fulfillment(of: [authenticated, clientReady], timeout: 8)
            let graphicsSender = DynamicVCManager()
            graphicsSender.send = { _ in }
            graphicsSender.handle(pdu: [0x50, 0, 3, 0])
            graphicsSender.createChannel(name: DynamicVCManager.graphicsDVCName)
            graphicsSender.handle(pdu: [0x10, 1, 0, 0, 0, 0])
            graphicsSender.sendBatch = { _, _, _ in 0 }
            graphicsSender.sendMultitransportBatch = { messages, priority, done in
                tunnel.send(messages, priority: priority, onWritten: done)
            }
            XCTAssertTrue(graphicsSender.switchToMultitransport(channelId: 1, onTCPFlushed: { _ in }))
            let frame = [[UInt8]](repeating: [UInt8](repeating: 0x5A, count: 240_000), count: 1)
            XCTAssertNotNil(graphicsSender.sendDataBatch(channelId: 1, payloads: frame,
                priority: .video, onWritten: { _ in flushed.fulfill() }))
            XCTAssertNotNil(graphicsSender.sendDataBatch(channelId: 1, payloads: frame,
                priority: .video, onWritten: { _ in flushed.fulfill() }))
            XCTAssertNil(graphicsSender.sendDataBatch(channelId: 1, payloads: frame, priority: .video))
            try await clientChannel.eventLoop.submit { client.send(Array("client ACK".utf8)) }.get()
            await fulfillment(of: [premature], timeout: 0.15)
            gate.open()
            tunnel.enableOutbound()
            tunnel.enableInbound()
            await fulfillment(of: [delivered, frames, flushed], timeout: 8)
            // Ninety-six MB of fragmented encrypted graphics crosses 65,535
            // reliable channel packets without sharing the SYN sequence space.
            tunnel.setTargetBitrate(100_000_000)
            let largeFrame = [[UInt8]](repeating: [UInt8](repeating: 0x5A, count: 6_000_000), count: 1)
            for group in wrapGroups {
                for _ in 0..<2 {
                    XCTAssertNotNil(graphicsSender.sendDataBatch(channelId: 1, payloads: largeFrame, priority: .video))
                }
                await fulfillment(of: [group], timeout: 15)
            }
            let crossedWrap = try await clientChannel.eventLoop.submit { client.sawReliableChannelWrap }.get()
            XCTAssertTrue(crossedWrap, "The encrypted test must actually receive channel 65535 followed by 1")
            XCTAssertTrue(tunnel.isReady)
        } catch {
            tunnel.close()
            try? await clientChannel.close().get(); try? await server.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
        tunnel.close()
        try await clientChannel.close().get()
        try await server.close().get()
        try await group.shutdownGracefully()
    }
}

private final class IntegrationTunnelHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var tunnel: MultitransportTunnel?
    var value: MultitransportTunnel? {
        get { lock.withLock { tunnel } }
        set { lock.withLock { tunnel = newValue } }
    }
}

private final class IntegrationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isOpen: Bool { lock.withLock { value } }
    func open() { lock.withLock { value = true } }
}

/// Owned by the client event loop; reject oversized DVC PDUs before reassembly.
private final class IntegrationDVCReceiver: @unchecked Sendable {
    private let manager = DynamicVCManager()
    private var frameIndex = 0
    init(onFrame: @escaping @Sendable ([UInt8], Int) -> Void) {
        manager.setDataHandler(channelId: 1) { [weak self] bytes in
            guard let self else { return }
            let index = frameIndex
            frameIndex += 1
            onFrame(bytes, index)
        }
    }
    func receive(_ pdu: [UInt8]) {
        XCTAssertLessThanOrEqual(pdu.count, 1600)
        manager.handle(pdu: pdu)
    }
}

/// Test client uses real UDP sockets and NIOSSL's certificate-verified TLS client.
/// Fixed wire handshake bytes are built independently from the server's SYN parser.
private final class IntegrationUDPClient: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    private let server: SocketAddress
    private let tunnel: MultitransportTunnel
    private let ssl: NIOSSLContext
    private let expectedCertificate: NIOSSLCertificate
    private let connected: @Sendable () -> Void
    private let received: @Sendable ([UInt8]) -> Void
    private let initial: UInt32 = 0xFA83_8DA7
    private var channel: Channel?
    private var stream: RDPUDPStream?
    private var engine: RDPUDP2Connection?
    private var timer: Scheduled<Void>?
    private var pumping = false
    private var closing = false
    private var sawLastReliableChannel = false
    private(set) var sawReliableChannelWrap = false

    init(server: SocketAddress, tunnel: MultitransportTunnel, ssl: NIOSSLContext, expectedCertificate: NIOSSLCertificate,
         connected: @escaping @Sendable () -> Void, received: @escaping @Sendable ([UInt8]) -> Void) {
        self.server = server; self.tunnel = tunnel; self.ssl = ssl
        self.expectedCertificate = expectedCertificate
        self.connected = connected; self.received = received
    }

    func channelActive(context: ChannelHandlerContext) {
        channel = context.channel
        var syn: [UInt8] = []
        syn.appendU32(UInt32.max, endian: .big); syn.appendU16(1024, endian: .big); syn.appendU16(0x1001, endian: .big)
        syn.appendU32(initial, endian: .big); syn.appendU16(1232, endian: .big); syn.appendU16(1232, endian: .big)
        syn.appendU16(1, endian: .big); syn.appendU16(0x0101, endian: .big); syn += tunnel.cookieHash
        syn += repeatElement(0, count: 1232 - syn.count)
        write(syn)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        guard envelope.remoteAddress == server else { return }
        let bytes = Array(envelope.data.readableBytesView)
        do {
            if engine == nil {
                var b = ByteBuffer(bytes: bytes)
                guard b.readInteger(endianness: .big, as: UInt32.self) == initial,
                      let window = b.readInteger(endianness: .big, as: UInt16.self),
                      b.readInteger(endianness: .big, as: UInt16.self) == 0x1005,
                      b.readInteger(endianness: .big, as: UInt32.self) != nil else { return }
                // DATA starts at 100 regardless of either endpoint's SYN ISN.
                engine = RDPUDP2Connection(mtu: 1232,
                                           peerWindow: Int(window), now: DispatchTime.now().uptimeNanoseconds)
                let stream = RDPUDPStream(parent: context.channel, remoteAddress: server)
                self.stream = stream
                stream.onWrite = { [weak self] b, done in try self?.engine?.enqueue(b, onSent: done) }
                stream.onFlush = { [weak self] in self?.pump() }
                // RDP's self-signed leaf is pinned to the certificate from the main connection.
                let expectedCertificate = self.expectedCertificate
                try stream.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: ssl, serverHostname: "localhost",
                    customVerificationCallback: { chain, promise in
                        promise.succeed(chain == [expectedCertificate] ? .certificateVerified : .failed)
                    }))
                try stream.pipeline.syncOperations.addHandler(PlainClient(owner: self))
                stream.registerAlreadyConfigured0(promise: nil)
            } else {
                let packet = try RDPUDP2Packet.parse(bytes)
                if !packet.dummy, let channelSequence = packet.data?.channelSequence {
                    XCTAssertNotEqual(channelSequence, 0, "Windows reserves reliable channel zero")
                    if channelSequence == UInt16.max { sawLastReliableChannel = true }
                    if sawLastReliableChannel && channelSequence == 1 { sawReliableChannelWrap = true }
                }
                for chunk in try engine!.receive(packet, now: DispatchTime.now().uptimeNanoseconds) { stream?.receive(chunk) }
            }
            pump()
        } catch { XCTFail("UDP/TLS client failed: \(error)"); context.close(promise: nil) }
    }

    func send(_ bytes: [UInt8]) {
        stream?.writeAndFlush(ByteBuffer(bytes: MultitransportPDU.TunnelMessage(action: .data, payload: bytes).encode()), promise: nil)
    }

    private func pump() {
        guard !pumping, let channel, let engine else { return }
        pumping = true
        defer { pumping = false }
        timer?.cancel()
        let now = DispatchTime.now().uptimeNanoseconds
        do {
            for output in try engine.transmit(now: now) {
                var bytes = output.bytes
                if try RDPUDP2Packet.parse(bytes).data != nil {
                    // mstsc begins TLS in DATA without a separate SYN acknowledgement.
                    bytes[2] |= 0x02 // undocumented 0x200 flag, with no extra field
                }
                write(bytes, done: output.onSent)
            }
            if let deadline = engine.nextDeadline(now: now) {
                timer = channel.eventLoop.scheduleTask(deadline: .uptimeNanoseconds(deadline)) { [weak self] in self?.pump() }
            }
        } catch { XCTFail("UDP client transport failed: \(error)") }
    }

    private func write(_ bytes: [UInt8], done: RDPUDP2Connection.Completion? = nil) {
        guard let channel else { return }
        let promise = channel.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenSuccess { done?() }
        promise.futureResult.whenFailure { XCTFail("UDP client socket failed: \($0)") }
        channel.writeAndFlush(AddressedEnvelope(remoteAddress: server, data: ByteBuffer(bytes: bytes)), promise: promise)
    }

    func channelInactive(context: ChannelHandlerContext) {
        closing = true
        timer?.cancel()
        stream?.close0(error: ChannelError.ioOnClosedChannel, mode: .all, promise: nil)
        stream = nil; engine = nil; channel = nil
    }

    private final class PlainClient: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        private weak var owner: IntegrationUDPClient?
        private var buffer = ByteBuffer()
        init(owner: IntegrationUDPClient) { self.owner = owner }
        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if case TLSUserEvent.handshakeCompleted = event, let owner {
                var create: [UInt8] = []
                create.appendU32(owner.tunnel.requestID); create.appendU32(0); create += owner.tunnel.cookie
                context.writeAndFlush(NIOAny(ByteBuffer(bytes: MultitransportPDU.TunnelMessage(action: .createRequest, payload: create).encode())), promise: nil)
            }
            context.fireUserInboundEventTriggered(event)
        }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var bytes = unwrapInboundIn(data)
            buffer.writeBuffer(&bytes)
            do {
                while let message = try MultitransportPDU.TunnelMessage.read(from: &buffer) {
                    if message.action == .createResponse {
                        XCTAssertEqual(message.payload, [0, 0, 0, 0]); owner?.connected()
                    } else { owner?.received(message.payload) }
                }
                if buffer.readerIndex > 65_535 { buffer.discardReadBytes() }
            } catch { XCTFail("Tunnel client framing failed: \(error)") }
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) {
            if owner?.closing != true { XCTFail("TLS client failed: \(error)") }
        }
    }
}
