import Foundation

/// MS-RDPEDISP display resizing for the server's single desktop surface.
public final class DisplayControlChannel {
    public static let dvcName = "Microsoft::Windows::RDS::DisplayControl"
    public var send: (([UInt8]) -> Void)?
    public var onResize: ((Int, Int) -> Void)?

    private var lastResize: (Int, Int)?
    private var lastResizeAt: Date = .distantPast

    public init() {}

    public func attach(send: @escaping ([UInt8]) -> Void) {
        self.send = send
        lastResize = nil
        var caps: [UInt8] = []
        caps.appendU32(0x0000_0005)
        caps.appendU32(20)
        caps.appendU32(1) // One monitor, matching the single capture/surface.
        caps.appendU32(8192)
        caps.appendU32(8192)
        send(caps)
        RDPLog.channels.info("DisplayControl: attached and sent single-monitor CAPS")
    }

    public func handle(_ data: [UInt8]) {
        guard data.count == 56, u32(data, 0) == 0x0000_0002,
              u32(data, 4) == UInt32(data.count), u32(data, 8) == 40,
              u32(data, 12) == 1, u32(data, 16) == 1,
              u32(data, 20) == 0, u32(data, 24) == 0 else {
            RDPLog.channels.error("DisplayControl: invalid single-monitor layout")
            return
        }
        let width = Int(u32(data, 28))
        let height = Int(u32(data, 32))
        guard (200...8192).contains(width), width.isMultiple(of: 2),
              (200...8192).contains(height) else { return }

        let now = Date()
        if let last = lastResize, last.0 == width, last.1 == height,
           now.timeIntervalSince(lastResizeAt) < 0.4 { return }
        lastResize = (width, height)
        lastResizeAt = now
        RDPLog.channels.info("DisplayControl: resize request \(width)x\(height)")
        onResize?(width, height)
    }

    private func u32(_ data: [UInt8], _ offset: Int) -> UInt32 {
        data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }
}
