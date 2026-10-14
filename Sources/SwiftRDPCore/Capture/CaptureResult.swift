import Foundation

/// One native callback result with cancellation and a bounded wait.
final class CaptureResult<Value: Sendable>: Sendable {
    private let values: AsyncThrowingStream<Value, Error>
    private let continuation: AsyncThrowingStream<Value, Error>.Continuation

    init() {
        (values, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func succeed(_ value: Value) {
        continuation.yield(value)
        continuation.finish()
    }

    func fail(_ error: Error) {
        continuation.finish(throwing: error)
    }

    func wait(timeoutNanoseconds: UInt64, timeoutError: Error) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                for try await value in self.values { return value }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw timeoutError
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CancellationError() }
            try Task.checkCancellation()
            return value
        }
    }
}
