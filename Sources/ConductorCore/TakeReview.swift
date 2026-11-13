import Foundation

public enum BeatOrigin: String, Codable, Sendable {
    case attack, inferred, release, manual
    public var label: String {
        switch self {
        case .attack: return "Recognized attack"
        case .inferred: return "Inferred from phrase"
        case .release: return "Estimated release"
        case .manual: return "Manual timing"
        }
    }
}

/// Makes a listening copy; the recorded samples and the proposed map are immutable.
public enum TakeReviewAudio {
    public static func render(samples: [Float], sampleRate: Double, beats: [BeatTime], clickLevel: Double) throws -> [Float] {
        guard sampleRate.isFinite, (1...384000).contains(sampleRate), !samples.isEmpty,
              samples.allSatisfy({ $0.isFinite }), clickLevel.isFinite else { throw MusicalError("This take cannot be played.") }
        guard !beats.isEmpty, clickLevel > 0 else { return samples }
        guard beats.allSatisfy({ $0.quarter.isFinite }) else { throw MusicalError("Invalid score positions in beat map.") }
        try Interpretation.validate(beats, duration: Double(samples.count) / sampleRate)
        let length = max(1, Int(sampleRate * 0.035))
        let last = Int((beats.last!.time * sampleRate).rounded())
        var mixed = samples + [Float](repeating: 0, count: max(0, last + length - samples.count))
        let gain = min(1, max(0, clickLevel)) * 0.35
        for beat in beats {
            let start = Int((beat.time * sampleRate).rounded())
            let downbeat = abs(beat.quarter.truncatingRemainder(dividingBy: 4)) < 1e-7
            let frequency = downbeat ? 1400.0 : 950.0
            for i in 0..<length {
                let t = Double(i) / sampleRate
                let envelope = min(1, t / 0.001) * exp(-t * 120)
                mixed[start + i] += Float(gain * envelope * sin(2 * .pi * frequency * t))
            }
        }
        let peak = mixed.reduce(Float(0)) { max($0, abs($1)) }
        if peak > 0.98 { let scale = 0.98 / peak; for i in mixed.indices { mixed[i] *= scale } }
        return mixed
    }
}
