import Foundation

/// Thin transport wrapper for per-session socket write/close callbacks.
public final class RDPSocket {
    public enum WritePriority: Sendable {
        case control
        case audio
        case video
    }

    public var onWrite: (([UInt8]) -> Void)?
    public var onPrioritizedWrite: (([UInt8], WritePriority) -> Bool)?
    public var onClose: (() -> Void)?

    public init() {}

    @discardableResult
    public func write(_ bytes: [UInt8], priority: WritePriority = .control) -> Bool {
        if let onPrioritizedWrite {
            return onPrioritizedWrite(bytes, priority)
        } else {
            onWrite?(bytes)
            return true
        }
    }

    public func close() {
        onClose?()
    }
}
