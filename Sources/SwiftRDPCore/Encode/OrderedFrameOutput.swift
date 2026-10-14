/// Bounded submission order, including outputs waiting for an earlier frame.
struct OrderedFrameOutput<Output> {
    let capacity: Int
    private var submitted: [Int64] = []
    private var ready: [Int64: Output] = [:]

    var count: Int { submitted.count }
    var isEmpty: Bool { submitted.isEmpty }

    mutating func reserve(_ id: Int64) -> Bool {
        guard submitted.count < capacity, !submitted.contains(id) else { return false }
        submitted.append(id)
        return true
    }

    mutating func complete(_ id: Int64, with output: Output) -> [Output] {
        guard submitted.contains(id), ready[id] == nil else { return [] }
        ready[id] = output
        var completed: [Output] = []
        while let first = submitted.first, let next = ready.removeValue(forKey: first) {
            submitted.removeFirst()
            completed.append(next)
        }
        return completed
    }

    mutating func reset() {
        submitted.removeAll(keepingCapacity: true)
        ready.removeAll(keepingCapacity: true)
    }
}
