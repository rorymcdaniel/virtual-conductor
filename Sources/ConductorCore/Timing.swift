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
    public let preparationStartQuarter: Double
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
        preparationStartQuarter = startQuarter - Double(prepBeats)
        // Preparation is the preceding score passage. Negative quarters provide
        // a silent count-in at the opening tempo when it extends before bar 1.
        let preparationStartSeconds = midi.seconds(atQuarter: preparationStartQuarter)
        leadSeconds = 60 / midi.tempo(atSeconds: preparationStartSeconds)
        prepSeconds = leadSeconds + startSeconds - preparationStartSeconds
        musicalEnd = prepSeconds + midi.duration - startSeconds
        totalBeats = prepBeats + Int(ceil(midi.endQuarter - startQuarter))
    }

    public func performanceTime(scoreSeconds: Double) -> Double { prepSeconds + scoreSeconds - startSeconds }
    public func scoreTime(performanceSeconds: Double) -> Double { performanceSeconds - prepSeconds + startSeconds }

    public func beatTime(_ beat: Int) -> Double {
        performanceTime(scoreSeconds: midi.seconds(atQuarter: preparationStartQuarter + Double(beat)))
    }

    public func position(_ time: Double) -> ConductingPosition {
        if time < leadSeconds {
            return ConductingPosition(beat: 3, f: max(0, time) / leadSeconds, measure: nil, preparing: true, leadIn: true, ended: false, bpm: 60 / leadSeconds)
        }
        let seconds = scoreTime(performanceSeconds: time)
        let raw = midi.quarter(atSeconds: seconds), nearest = raw.rounded()
        let quarter = min(midi.endQuarter - 1e-8, abs(raw - nearest) < 1e-9 ? nearest : raw)
        return ConductingPosition(beat: (Int(floor(quarter)) % 4 + 4) % 4, f: quarter - floor(quarter),
            measure: Int(floor(quarter / 4)) + (quarter < 0 ? 0 : 1), preparing: time < prepSeconds,
            leadIn: false, ended: seconds >= midi.duration, bpm: midi.tempo(atSeconds: min(seconds, midi.duration)))
    }
}
