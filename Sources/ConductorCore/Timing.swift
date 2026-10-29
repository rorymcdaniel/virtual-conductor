import Foundation

public struct ConductingPosition: Equatable, Sendable {
    public let beat: Int
    public let f: Double
    public let measure: Int?
    public let preparing: Bool
    public let leadIn: Bool
    public let ended: Bool
    public let bpm: Double
}

public struct PerformanceTiming: Sendable {
    public let midi: MIDIFile
    public let prepBeats: Int
    public let leadSeconds: Double
    public let prepSeconds: Double
    public let musicalEnd: Double
    public let totalBeats: Int

    public init(midi: MIDIFile, preparatoryMeasures: Int) throws {
        guard (0...99).contains(preparatoryMeasures) else { throw MusicalError("Choose 0–99 whole preparatory measures.") }
        self.midi = midi
        prepBeats = preparatoryMeasures * 4
        leadSeconds = 60 / midi.openingBPM
        prepSeconds = leadSeconds + Double(prepBeats) * leadSeconds
        musicalEnd = prepSeconds + midi.duration
        totalBeats = prepBeats + Int(ceil(midi.endQuarter))
    }

    public func beatTime(_ beat: Int) -> Double {
        beat < prepBeats ? leadSeconds + Double(beat) * leadSeconds : prepSeconds + midi.seconds(atQuarter: Double(beat - prepBeats))
    }

    public func position(_ time: Double) -> ConductingPosition {
        if time < leadSeconds {
            return ConductingPosition(beat: 3, f: max(0, time) / leadSeconds, measure: nil, preparing: true, leadIn: true, ended: false, bpm: midi.openingBPM)
        }
        if time < prepSeconds {
            let quarter = (time - leadSeconds) / leadSeconds
            return ConductingPosition(beat: Int(floor(quarter)) % 4, f: quarter.truncatingRemainder(dividingBy: 1), measure: Int(floor(quarter / 4)) - prepBeats / 4, preparing: true, leadIn: false, ended: false, bpm: midi.openingBPM)
        }
        let seconds = max(0, time - prepSeconds)
        let raw = max(0, midi.quarter(atSeconds: seconds)), nearest = raw.rounded()
        let quarter = min(midi.endQuarter - 1e-8, abs(raw - nearest) < 1e-9 ? nearest : raw)
        return ConductingPosition(beat: Int(floor(quarter)) % 4, f: quarter.truncatingRemainder(dividingBy: 1), measure: Int(floor(quarter / 4)) + 1, preparing: false, leadIn: false, ended: seconds >= midi.duration, bpm: midi.tempo(atSeconds: min(seconds, midi.duration)))
    }
}
