import Foundation

/// Thin transport wrapper for per-session socket write/close callbacks.
public final class RDPSocket {
    public typealias WriteCompletion = @Sendable (UInt64) -> Void
    public enum WritePriority: Sendable {
        case control
        case graphicsControl
        case audio
        case video
    }

    public var onWrite: (([UInt8]) -> Void)?
    public var onPrioritizedWrite: (([[UInt8]], WritePriority, WriteCompletion?) -> Bool)?
    public var onClose: (() -> Void)?

    public init() {}

    @discardableResult
    public func write(_ bytes: [UInt8], priority: WritePriority = .control) -> Bool {
        writeBatch([bytes], priority: priority)
    }

    @discardableResult
    public func writeBatch(_ packets: [[UInt8]], priority: WritePriority, onWritten: WriteCompletion? = nil) -> Bool {
        if let onPrioritizedWrite {
            return onPrioritizedWrite(packets, priority, onWritten)
        } else {
            for packet in packets { onWrite?(packet) }
            onWritten?(DispatchTime.now().uptimeNanoseconds)
            return true
        }
    }

    public func close() {
        onClose?()
    }
}
