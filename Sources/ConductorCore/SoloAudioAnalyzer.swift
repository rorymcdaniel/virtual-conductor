import Foundation

/// Sample-clock observations shared by live following and recorded interpretation.
/// Each observation represents the centre of a 40 ms window, delivered every 10 ms.
public struct SoloObservation: Sendable, Equatable {
    public let pitch: Int?
    public let time: Double
    public let rearticulated: Bool
}

/// Incremental, bounded analysis. Chunk boundaries never change the result; all
/// frames are evaluated off the audio callback. The score supplies the beat grid,
/// so a run of eighth notes is not mistaken for a doubling of the musical tempo.
public struct SoloAudioAnalyzer: Sendable {
    private let factor: Int
    private let rate: Double
    private let size: Int
    private let hop: Int
    private var sum = 0.0
    private var summed = 0
    private var pcm: [Float] = []
    private var consumed = 0
    private var articulation = LiveArticulation()

    public init(sampleRate: Double) {
        let validRate = sampleRate.isFinite && (4000...384000).contains(sampleRate) ? sampleRate : 12000
        factor = max(1, Int(validRate / 12000))
        rate = validRate / Double(factor)
        size = Int((rate * 0.04).rounded())
        hop = Int((rate * 0.01).rounded())
        pcm.reserveCapacity(size)
    }

    public mutating func process(_ samples: [Float]) -> [SoloObservation] {
        var observations: [SoloObservation] = []
        for sample in samples {
            sum += sample.isFinite ? Double(sample) : 0; summed += 1
            guard summed == factor else { continue }
            pcm.append(Float(sum / Double(factor))); sum = 0; summed = 0
            guard pcm.count == size else { continue }
            let centre = size / 2
            let energy = pcm[(centre - hop / 2)..<(centre + hop / 2)].reduce(0.0) { $0 + Double($1) * Double($1) }
            let rms = sqrt(energy / Double(hop))
            let time = Double(consumed + centre) / rate
            let attack = articulation.observe(rms: rms, time: time)
            // Periodicity, rather than a high input-level cutoff, rejects noise.
            // This floor is -80 dBFS; DC and nonperiodic input fail the pitch test.
            let pitch = rms >= 0.0001 ? LivePitch.detect(samples: pcm, sampleRate: rate, floor: 0.0001) : nil
            observations.append(SoloObservation(pitch: pitch, time: time, rearticulated: attack))
            pcm.removeFirst(hop); consumed += hop
        }
        return observations
    }
}
