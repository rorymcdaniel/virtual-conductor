import Foundation

public enum FollowingDiagnosticPhase: String, Codable, Sendable {
    case audio, free, wait, cadenza
    static func legacy(_ description: String) -> Self? {
        description.split(separator: "(").first.flatMap { Self(rawValue: String($0)) }
    }
}

/// The state immediately before each decision makes even a trimmed excerpt
/// replayable, including waits, resets, and starts in the middle of a score.
public struct FollowingDecision: Codable, Sendable {
    public let tracker: SoloTracker
    public let pitch: Int?
    public let time: Double
    public let expectedQuarter: Double
    public let free: Bool
    public let throughQuarter: Double
    public let rearticulated: Bool
    public let matched: Int?
    public let rate: Double
    public let phase: String
    public let phaseKind: FollowingDiagnosticPhase?
    public var resolvedPhase: FollowingDiagnosticPhase? { phaseKind ?? FollowingDiagnosticPhase.legacy(phase) }
    public let level: Float
    public init(tracker: SoloTracker, pitch: Int?, time: Double, expectedQuarter: Double, free: Bool,
                throughQuarter: Double, rearticulated: Bool, matched: Int?, rate: Double, phase: String, level: Float) {
        self.tracker = tracker; self.pitch = pitch; self.time = time; self.expectedQuarter = expectedQuarter
        self.free = free; self.throughQuarter = throughQuarter; self.rearticulated = rearticulated
        self.matched = matched; self.rate = rate; self.phase = phase; self.level = level
        self.phaseKind = FollowingDiagnosticPhase.legacy(phase)
    }
}
public struct DiagnosticNotice: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case information, started, stopped, manualCue, interruption }
    public let time: Double
    public let reason: String
    public let kind: Kind?
    public init(time: Double, reason: String, kind: Kind = .information) {
        self.time = time; self.reason = reason; self.kind = kind
    }
    public var interruptsReplay: Bool {
        if let kind { return kind == .stopped || kind == .started || kind == .manualCue || kind == .interruption }
        // Compatibility only: older reports did not have stable lifecycle kinds.
        return reason.contains("discontinuity") || reason.contains("pedal") || reason.contains("stopped") || reason.contains("started")
    }
}
public struct FollowingDiagnostic: Codable, Sendable {
    public var version = 1
    public let created: Date
    public let sampleRate: Double
    public let tolerance: Double
    public let notes: [MIDINote]
    public let midi: MIDIFile
    public var decisions: [FollowingDecision]
    public var notices: [DiagnosticNotice]
    // Optional additions keep older version-1 reports readable.
    public var controls: [FollowingControlDecision]?
    public var audioStart: Double?
    public var audioEnd: Double?
    public init(sampleRate: Double, tolerance: Double, notes: [MIDINote], midi: MIDIFile) {
        created = Date(); self.sampleRate = sampleRate; self.tolerance = tolerance; self.notes = notes; self.midi = midi
        decisions = []; notices = []
        controls = []
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try encoder.encode(self)
    }
    public static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let report = try decoder.decode(Self.self, from: data)
        guard report.version == 1, !report.midi.segments.isEmpty,
              report.midi.segments.allSatisfy({ $0.quarter.isFinite && $0.seconds.isFinite && $0.secondsPerQuarter.isFinite && $0.secondsPerQuarter > 0 }),
              report.notes.allSatisfy({ $0.startQuarter.isFinite && $0.endQuarter.isFinite }),
              report.decisions.allSatisfy({ $0.time.isFinite && $0.expectedQuarter.isFinite && !$0.throughQuarter.isNaN &&
                  $0.tracker.validForReplay(noteCount: report.notes.count) && ($0.pitch.map { (0...127).contains($0) } ?? true) }),
              report.controls?.allSatisfy({ $0.time.isFinite && $0.scoreTime.isFinite && $0.plannedBPM.isFinite &&
                  $0.plannedBPM > 0 && $0.input.valid && $0.before.rate.isFinite && (0.25...1.75).contains($0.before.rate) &&
                  $0.rate.isFinite && (0.25...1.75).contains($0.rate) }) ?? true else {
            throw MusicalError("Unsupported or invalid following diagnostic.")
        }
        return report
    }
    /// Re-evaluate each captured decision with its original phrase context.
    public func replay() -> [Int] {
        decisions.indices.filter { i in
            let event = decisions[i]
            var tracker = event.tracker
            let match = tracker.observe(pitch: event.pitch, time: event.time, notes: notes, expectedQuarter: event.expectedQuarter,
                                        free: event.free, midi: midi, rearticulated: event.rearticulated, throughQuarter: event.throughQuarter)
            return match != event.matched || abs(tracker.rate - event.rate) > 1e-9
        }
    }

    public func replayControls() -> [Int] {
        let events = controls ?? []
        return events.indices.filter { i in
            var controller = events[i].before
            return abs(controller.update(events[i].input) - events[i].rate) > 1e-9
        }
    }
}
