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
    public let startMeasure: Int
    public let startQuarter: Double
    public let startSeconds: Double
    public let startingBPM: Double
    public let prepBeats: Int
    public let leadSeconds: Double
    public let prepSeconds: Double
    public let musicalEnd: Double
    public let totalBeats: Int

    public init(midi: MIDIFile, preparatoryMeasures: Int, startMeasure: Int = 1) throws {
        guard (0...99).contains(preparatoryMeasures) else { throw MusicalError("Choose 0–99 whole preparatory measures.") }
        guard (1...midi.measures).contains(startMeasure) else { throw MusicalError("Choose a start measure from 1 to \(midi.measures).") }
        self.midi = midi
        self.startMeasure = startMeasure
        startQuarter = Double(startMeasure - 1) * 4
        startSeconds = midi.seconds(atQuarter: startQuarter)
        startingBPM = midi.tempo(atSeconds: startSeconds)
        prepBeats = preparatoryMeasures * 4
        leadSeconds = 60 / startingBPM
        prepSeconds = leadSeconds + Double(prepBeats) * leadSeconds
        musicalEnd = prepSeconds + midi.duration - startSeconds
        totalBeats = prepBeats + Int(ceil(midi.endQuarter - startQuarter))
    }

    public func performanceTime(scoreSeconds: Double) -> Double { prepSeconds + scoreSeconds - startSeconds }
    public func scoreTime(performanceSeconds: Double) -> Double { performanceSeconds - prepSeconds + startSeconds }

    public func beatTime(_ beat: Int) -> Double {
        beat < prepBeats ? leadSeconds + Double(beat) * leadSeconds : performanceTime(scoreSeconds: midi.seconds(atQuarter: startQuarter + Double(beat - prepBeats)))
    }

    public func position(_ time: Double) -> ConductingPosition {
        if time < leadSeconds {
            return ConductingPosition(beat: 3, f: max(0, time) / leadSeconds, measure: nil, preparing: true, leadIn: true, ended: false, bpm: startingBPM)
        }
        if time < prepSeconds {
            let quarter = (time - leadSeconds) / leadSeconds
            return ConductingPosition(beat: Int(floor(quarter)) % 4, f: quarter.truncatingRemainder(dividingBy: 1), measure: Int(floor(quarter / 4)) - prepBeats / 4, preparing: true, leadIn: false, ended: false, bpm: startingBPM)
        }
        let seconds = max(startSeconds, scoreTime(performanceSeconds: time))
        let raw = max(0, midi.quarter(atSeconds: seconds)), nearest = raw.rounded()
        let quarter = min(midi.endQuarter - 1e-8, abs(raw - nearest) < 1e-9 ? nearest : raw)
        return ConductingPosition(beat: Int(floor(quarter)) % 4, f: quarter.truncatingRemainder(dividingBy: 1), measure: Int(floor(quarter / 4)) + 1, preparing: false, leadIn: false, ended: seconds >= midi.duration, bpm: midi.tempo(atSeconds: min(seconds, midi.duration)))
    }
}
