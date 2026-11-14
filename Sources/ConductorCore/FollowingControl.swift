import Foundation

/// The evidence used for one accompaniment adjustment. Times are seconds on
/// the original MIDI timeline, excluding count-in/preparation.
public struct FollowingTempoInput: Codable, Sendable {
    public let delta: Double
    public let tolerance: Double
    public let trackedRate: Double
    public let phaseError: Double
    public let age: Double
    public let reliable: Bool

    public init(delta: Double, tolerance: Double, trackedRate: Double, phaseError: Double, age: Double, reliable: Bool) {
        self.delta = delta; self.tolerance = tolerance; self.trackedRate = trackedRate
        self.phaseError = phaseError; self.age = age; self.reliable = reliable
    }

    public static func accompanied(delta: Double, tolerance: Double, tracker: SoloTracker,
                                   notes: [MIDINote], midi: MIDIFile, scoreTime: Double, time: Double) -> Self {
        let quarter = midi.quarter(atSeconds: scoreTime)
        let note = tracker.index.map { notes[$0] }
        let expectingSound = notes.contains { $0.startQuarter <= quarter && quarter < $0.endQuarter }
        let age = time - tracker.lastMatch
        let error = note.map {
            min(midi.seconds(atQuarter: $0.endQuarter), midi.seconds(atQuarter: $0.startQuarter) +
                (time - tracker.lastAttack) * tracker.rate) - scoreTime
        } ?? 0
        // Carry the established pace through a written rest without steering
        // back toward the preceding note's end.
        return Self(delta: delta, tolerance: tolerance, trackedRate: tracker.rate,
                    phaseError: expectingSound ? error : 0,
                    age: !expectingSound && note != nil && age < 1.5 ? 0 : age,
                    reliable: tracker.hasReliableTempo)
    }

    public var reason: String {
        if !reliable { return "Holding tempo: uncertain phrase" }
        if age >= 0.6 { return "Holding tempo: no recent match" }
        if abs(phaseError) > 0.035 { return "Following phrase with gentle position correction" }
        return "Following phrase tempo"
    }

    public var isHolding: Bool { !reliable || age >= 0.6 }
    public var valid: Bool {
        delta.isFinite && delta >= 0 && tolerance.isFinite && (0...0.75).contains(tolerance) &&
        trackedRate.isFinite && (0.1...4).contains(trackedRate) && phaseError.isFinite &&
        (age.isFinite || age == .infinity)
    }
}

public extension FollowingTempo {
    mutating func update(_ input: FollowingTempoInput) -> Double {
        update(delta: input.delta, tolerance: input.tolerance, trackedRate: input.trackedRate,
               phaseError: input.phaseError, age: input.age, reliable: input.reliable)
    }
}

/// Records commanded playback, not a measurement of acoustic output latency.
public struct FollowingControlDecision: Codable, Sendable {
    public let time: Double
    public let scoreTime: Double
    public let plannedBPM: Double
    public let before: FollowingTempo
    public let input: FollowingTempoInput
    public let rate: Double
    public let reason: String

    public init(time: Double, scoreTime: Double, plannedBPM: Double, before: FollowingTempo,
                input: FollowingTempoInput, rate: Double) {
        self.time = time; self.scoreTime = scoreTime; self.plannedBPM = plannedBPM
        self.before = before; self.input = input; self.rate = rate
        self.reason = input.reason
    }
}
