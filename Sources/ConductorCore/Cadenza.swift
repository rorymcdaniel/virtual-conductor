import Foundation

public struct CadenzaPassage: Codable, Equatable, Sendable {
    public let startMeasure: Int
    public let startBeat: Int
    public let returnMeasure: Int
    public let returnBeat: Int
    public init(startMeasure: Int, startBeat: Int, returnMeasure: Int, returnBeat: Int) {
        self.startMeasure = startMeasure; self.startBeat = startBeat
        self.returnMeasure = returnMeasure; self.returnBeat = returnBeat
    }
}

public struct CompiledCadenza: Equatable, Sendable {
    public let passage: CadenzaPassage
    public let startQuarter: Double
    public let returnQuarter: Double
    public let startSeconds: Double
    public let returnSeconds: Double
}

public func compileCadenzas(_ passages: [CadenzaPassage], midi: MIDIFile, audioDuration: Double) throws -> [CompiledCadenza] {
    func position(_ measure: Int, _ beat: Int, _ label: String) throws -> Double {
        guard measure >= 1, (1...4).contains(beat) else {
            throw MusicalError("\(label): choose a whole measure number and a whole beat from 1 to 4.")
        }
        // Compute in floating point to avoid overflow from untrusted settings.
        let quarter = (Double(measure) - 1) * 4 + Double(beat) - 1
        guard quarter < midi.endQuarter else { throw MusicalError("\(label) is outside this score.") }
        return quarter
    }
    let result = try passages.enumerated().map { index, passage in
        let label = "Passage \(index + 1)"
        let start = try position(passage.startMeasure, passage.startBeat, "\(label) start")
        let end = try position(passage.returnMeasure, passage.returnBeat, "\(label) return")
        guard end > start else { throw MusicalError("\(label): return must be after the start.") }
        let startSeconds = midi.seconds(atQuarter: start), returnSeconds = midi.seconds(atQuarter: end)
        guard audioDuration.isFinite, returnSeconds < audioDuration else { throw MusicalError("\(label): return is beyond the accompaniment audio.") }
        return CompiledCadenza(passage: passage, startQuarter: start, returnQuarter: end, startSeconds: startSeconds, returnSeconds: returnSeconds)
    }.sorted { $0.startQuarter < $1.startQuarter }
    for index in result.indices.dropFirst() {
        guard result[index].startQuarter > result[index - 1].returnQuarter else {
            throw MusicalError("Each cadenza passage must start after the previous passage’s return. Passages cannot overlap.")
        }
    }
    return result
}

/// Advisory sound-level check, including every channel and excluding the return sample.
public func accompanimentInCadenzas(_ passages: [CompiledCadenza], channels: [[Float]], sampleRate: Double) -> [CompiledCadenza] {
    guard sampleRate.isFinite, sampleRate > 0, sampleRate < Double(Int.max) / 100 else { return [] }
    let windowSize = max(1, Int((sampleRate * 0.01).rounded()))
    return passages.filter { passage in
        for channel in channels {
            // Clamp in floating point before conversion to keep malformed ranges safe.
            let length = Double(channel.count)
            let start = Int(min(length, max(0, ceil(passage.startSeconds * sampleRate))))
            let end = Int(min(length, max(0, ceil(passage.returnSeconds * sampleRate))))
            var first = start
            while first < end {
                let last = first + min(windowSize, end - first)
                var power = 0.0
                for index in first..<last { let sample = Double(channel[index]); power += sample * sample }
                if power / Double(last - first) >= 1e-6 { return true }
                first = last
            }
        }
        return false
    }
}
