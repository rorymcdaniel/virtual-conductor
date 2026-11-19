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
    private let window: [Double]
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
        let length = size
        window = (0..<length).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(length)) }
        pcm.reserveCapacity(size)
    }

    public mutating func process(_ samples: [Float], returnCue: (preceding: Int, entrance: Int)? = nil) -> [SoloObservation] {
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
            var pitch = rms >= 0.0001 ? LivePitch.detect(samples: pcm, sampleRate: rate, floor: 0.0001) : nil
            if let cue = returnCue, let detected = pitch,
               resolvesEntrance(detected: detected, preceding: cue.preceding, entrance: cue.entrance) {
                pitch = cue.entrance
            }
            observations.append(SoloObservation(pitch: pitch, time: time, rearticulated: attack))
            pcm.removeFirst(hop); consumed += hop
        }
        return observations
    }

    // Two overlapping notes can share a period longer than either note's.
    // Test that interpretation only when both pitches are distinct low
    // harmonics of the detected period and neither can be an overtone of the other.
    private func resolvesEntrance(detected: Int, preceding: Int, entrance: Int) -> Bool {
        let harmonics = [12, 19, 24, 28, 31] // partials 2 through 6 in semitones
        guard let old = harmonics.firstIndex(of: preceding - detected),
              let new = harmonics.firstIndex(of: entrance - detected),
              (old + 2) % (new + 2) != 0, (new + 2) % (old + 2) != 0 else { return false }
        let windowed = zip(pcm, window).map { Double($0) * $1 }
        func power(_ pitch: Int) -> Double {
            let frequency = 440 * pow(2, Double(pitch - 69) / 12)
            let coefficient = 2 * cos(2 * .pi * frequency / rate)
            var previous = 0.0, older = 0.0
            for sample in windowed {
                let current = sample + coefficient * previous - older
                older = previous
                previous = current
            }
            return previous * previous + older * older - coefficient * previous * older
        }
        let expected = power(entrance)
        let ringing = power(preceding)
        return expected > ringing * 0.2 && ringing > expected * 0.01 &&
            expected > 40 * power(detected) && expected > 20 * power(entrance - 12) &&
            expected > power(entrance - 1) && expected > power(entrance + 1)
    }
}
