import Synchronization

/// One audio tap publishes complete, timestamped blocks to one analysis consumer.
final class LiveSampleBuffer: @unchecked Sendable {
    struct Batch {
        let samples: [Float]
        let start: Double
        let followsGap: Bool
    }

    private struct Block {
        let count: Int
        let start: Double
        let followsGap: Bool
    }

    private let capacity = 32768
    private let rate: Double
    private let samples: UnsafeMutablePointer<Float>
    // A header at the first frame of each block shares its lifetime in the ring.
    private let blocks: UnsafeMutablePointer<Block>
    private let written = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)
    let dropped = Atomic<Int>(0)
    // Accessed only by the producer.
    private var expectedHostTime: Double?
    private var expectedSampleTime: Int64?

    init(rate: Double) {
        self.rate = rate
        samples = .allocate(capacity: capacity)
        blocks = .allocate(capacity: capacity)
    }
    deinit { samples.deallocate(); blocks.deallocate() }

    func write(count: Int, start: Double, sampleTime: Int64? = nil, sample: (Int) -> Float) {
        guard count > 0 else { return }
        let w = written.load(ordering: .relaxed)
        guard count <= capacity - (w - consumed.load(ordering: .acquiring)) else {
            dropped.wrappingAdd(count, ordering: .releasing)
            return
        }
        let sampleGap = if let sampleTime, let expectedSampleTime { sampleTime != expectedSampleTime } else { false }
        let hostGap = expectedHostTime.map { abs(start - $0) > 0.04 } ?? false
        blocks[w % capacity] = Block(count: count, start: start, followsGap: sampleGap || hostGap)
        for i in 0..<count { samples[(w + i) % capacity] = sample(i) }
        expectedSampleTime = sampleTime.map { $0 + Int64(count) }
        expectedHostTime = start + Double(count) / rate
        written.store(w + count, ordering: .releasing)
    }

    func drain() -> Batch? {
        var r = consumed.load(ordering: .relaxed)
        let w = written.load(ordering: .acquiring)
        guard r < w else { return nil }
        var start = blocks[r % capacity].start, followsGap = false
        var result = [Float]()
        result.reserveCapacity(w - r)
        while r < w {
            let block = blocks[r % capacity]
            if block.followsGap {
                result.removeAll(keepingCapacity: true)
                start = block.start
                followsGap = true
            }
            for i in r..<(r + block.count) { result.append(samples[i % capacity]) }
            r += block.count
        }
        consumed.store(w, ordering: .releasing)
        return Batch(samples: result, start: start, followsGap: followsGap)
    }
}
