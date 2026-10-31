import Synchronization

/// Bounded single-producer/single-consumer queue. The producer never overwrites
/// unread samples; analysis owns a copied batch after advancing the read index.
final class LiveSampleBuffer: @unchecked Sendable {
    private let capacity = 32768
    private let samples: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)
    let dropped = Atomic<Int>(0)
    init() { samples = .allocate(capacity: capacity); samples.initialize(repeating: 0, count: capacity) }
    deinit { samples.deallocate() }
    func write(_ sample: Float) {
        let w = written.load(ordering: .relaxed)
        guard w - consumed.load(ordering: .acquiring) < capacity else {
            dropped.store(dropped.load(ordering: .relaxed) + 1, ordering: .releasing); return
        }
        samples[w % capacity] = sample
        written.store(w + 1, ordering: .releasing)
    }
    func drain() -> [Float] {
        let r = consumed.load(ordering: .relaxed), w = written.load(ordering: .acquiring)
        var result = [Float](); result.reserveCapacity(w - r)
        for i in r..<w { result.append(samples[i % capacity]) }
        consumed.store(w, ordering: .releasing)
        return result
    }
}
