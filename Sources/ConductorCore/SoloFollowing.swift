import Foundation

public struct WaitPoint: Codable, Equatable, Sendable {
    public var measure: Int
    public var beat: Double
    public init(measure: Int, beat: Double) { self.measure = measure; self.beat = beat }
    public var quarter: Double { (Double(measure) - 1) * 4 + beat - 1 }
}

/// All locations are on the score's linear quarter-note timeline, in concert pitch.
public struct FollowingPlan: Sendable {
    public let notes: [MIDINote]
    public let waits: [Double]
    public let freePassages: [PassageRange]
    public let cadenzas: [CompiledCadenza]
    public let end: Double

    public init(score: MusicXMLScore, solo: MusicXMLStaffID, waits: [WaitPoint], cadenzas: [CompiledCadenza]) throws {
        guard let staff = score.staves.first(where: { $0.id == solo }), !staff.notes.isEmpty else {
            throw MusicalError("Choose a MusicXML solo staff with pitched notes.")
        }
        notes = staff.notes
        guard notes.allSatisfy({ (0...127).contains($0.pitch) }) else {
            throw MusicalError("Live following needs a pitched solo staff without microtones or unpitched notes.")
        }
        for i in notes.indices.dropFirst() where notes[i].startQuarter < notes[i-1].endQuarter - 1e-7 {
            throw MusicalError("Live following currently needs one solo note at a time. Choose a monophonic solo staff.")
        }
        for wait in waits {
            guard wait.measure >= 1, wait.beat.isFinite, wait.beat >= 1, wait.beat < 5,
                  notes.contains(where: { abs($0.startQuarter - wait.quarter) < 1e-7 }) else {
                throw MusicalError("Each wait point must be at a solo note attack in MusicXML (measure and beat, including fractional beats). A rest or tied continuation cannot cue an entrance.")
            }
        }
        self.waits = Array(Set(waits.map(\.quarter))).sorted()
        self.cadenzas = cadenzas
        end = score.endQuarter
        // Union every non-solo staff, including other staves in the solo's part.
        let accompaniment = score.staves.filter { $0.id != solo }.flatMap(\.soundingIntervals)
            .sorted { $0.startQuarter < $1.startQuarter }
        var cursor = 0.0, gaps: [PassageRange] = []
        for interval in accompaniment {
            if interval.startQuarter > cursor { gaps.append(PassageRange(start: cursor, end: interval.startQuarter)) }
            cursor = max(cursor, interval.endQuarter)
        }
        if cursor < end { gaps.append(PassageRange(start: cursor, end: end)) }
        // Cadenza regions override free following. Retain qualifying silence on either side.
        for cadenza in cadenzas {
            gaps = gaps.flatMap { gap -> [PassageRange] in
                guard cadenza.startQuarter < gap.end, cadenza.returnQuarter > gap.start else { return [gap] }
                return [PassageRange(start: gap.start, end: min(gap.end, cadenza.startQuarter)),
                        PassageRange(start: max(gap.start, cadenza.returnQuarter), end: gap.end)]
                    .filter { $0.end > $0.start }
            }
        }
        freePassages = gaps.filter { gap in
            gap.end - gap.start >= 4 - 1e-7 && staff.notes.contains { $0.startQuarter >= gap.start && $0.startQuarter < gap.end }
        }
    }
}

public enum FollowingStatus: String, Sendable {
    case following = "Following"
    case waiting = "Waiting for you"
    case lost = "Tracking lost"
    case cadenza = "Cadenza · use pedal"
    case finished = "Finished"
}

/// Stateful, local phrase matching. Only fresh attacks advance repeated pitches.
/// Missed/wrong notes are tolerated by searching ahead; time is a prior, never a
/// command to advance a freely played passage. No audio or UI dependencies.
public struct SoloTracker: Sendable {
    public private(set) var index: Int?
    public private(set) var lastMatch = -Double.infinity
    public private(set) var lastAttack = -Double.infinity
    public private(set) var releasedAt: Double?
    public private(set) var rate = 1.0
    private var previousPitch: Int?
    private var candidatePitch: Int?
    private var candidateCount = 0
    private var silentFrames = 0
    private var lastAttackQuarter: Double?
    private var lastAttackTime: Double?
    private var searchStart = 0

    public init() {}
    public mutating func reset(notes: [MIDINote], quarter: Double, preservingSound: Bool = false) {
        let sounding = previousPitch, candidate = candidatePitch, count = candidateCount
        self = SoloTracker()
        if preservingSound { previousPitch = sounding; candidatePitch = candidate; candidateCount = count }
        searchStart = notes.firstIndex { $0.endQuarter > quarter + 1e-7 } ?? notes.count
    }

    @discardableResult
    public mutating func observe(pitch: Int?, time: Double, notes: [MIDINote], expectedQuarter: Double,
                                 free: Bool, midi: MIDIFile, rearticulated: Bool = false) -> Int? {
        guard let pitch else {
            silentFrames += 1
            if silentFrames >= 2 { previousPitch = nil; if releasedAt == nil { releasedAt = time } }
            candidatePitch = nil; candidateCount = 0
            return nil
        }
        silentFrames = 0
        if candidatePitch == pitch { candidateCount += 1 } else { candidatePitch = pitch; candidateCount = 1 }
        guard candidateCount >= 2 else { return nil }
        let attack = previousPitch != pitch || rearticulated
        previousPitch = pitch
        if !attack, let index, notes[index].pitch == pitch {
            lastMatch = time; releasedAt = nil
            return nil
        }
        guard attack else { return nil }
        let lower = max(searchStart, (index ?? (searchStart - 1)) + 1)
        var candidates = Array(lower..<min(notes.count, lower + 8))
        if !free {
            // Permit reacquisition near the sounding accompaniment after extended loss.
            candidates += notes.indices.filter { abs(notes[$0].startQuarter - expectedQuarter) < 4 && $0 >= lower }
        }
        guard let match = candidates.filter({ notes[$0].pitch == pitch }).min(by: {
            if free { return $0 < $1 }
            return abs(notes[$0].startQuarter - expectedQuarter) < abs(notes[$1].startQuarter - expectedQuarter)
        }) else { return nil }
        if let quarter = lastAttackQuarter, let host = lastAttackTime, time - host > 0.08 {
            let ratio = (midi.seconds(atQuarter: notes[match].startQuarter) - midi.seconds(atQuarter: quarter)) / (time - host)
            rate = min(4, max(0.1, ratio))
        }
        index = match; lastMatch = time; lastAttack = time; releasedAt = nil
        lastAttackQuarter = notes[match].startQuarter; lastAttackTime = time
        return match
    }
}

/// Detects a new attack on a repeated pitch from a short amplitude dip and rise.
/// Feed nonoverlapping 10 ms RMS frames, not individual waveform samples.
public struct LiveArticulation: Sendable {
    private var envelope = 0.0
    private var dipped = false
    private var lastAttack = -Double.infinity
    public init() {}
    public mutating func observe(rms: Double, time: Double) -> Bool {
        guard rms.isFinite, rms >= 0 else { return false }
        envelope = max(rms, envelope * 0.995)
        if envelope > 0.004 && rms < envelope * 0.25 { dipped = true }
        if dipped && rms > max(0.003, envelope * 0.6) && time - lastAttack > 0.08 {
            dipped = false; lastAttack = time; return true
        }
        return false
    }
}

/// Smoothed bounded rate control. Loss falls back to the planned tempo; phase
/// correction never changes the playback position or exceeds the user's limit.
public struct FollowingTempo: Sendable {
    public private(set) var rate = 1.0
    public init() {}
    public mutating func reset() { rate = 1 }
    public mutating func update(delta: Double, tolerance: Double, trackedRate: Double, phaseError: Double, age: Double) -> Double {
        let bound = min(0.75, max(0, tolerance))
        let target: Double
        if age < 0.6 { target = min(1 + bound, max(1 - bound, trackedRate + phaseError * 0.2)) }
        else if age < 1.5 { target = rate }
        else { target = 1 }
        rate += (target - rate) * (1 - exp(-max(0, delta) / 0.35))
        rate = min(1 + bound, max(1 - bound, rate))
        return rate
    }
}

/// A small YIN detector for one live analysis window; work runs off the audio tap.
public enum LivePitch {
    public static func detect(samples: [Float], sampleRate: Double, floor: Double = 0.003) -> Int? {
        guard sampleRate.isFinite, sampleRate >= 4000, sampleRate <= 384000, samples.count >= 512 else { return nil }
        let factor = max(1, Int(sampleRate / 12000)), rate = sampleRate / Double(factor)
        let count = samples.count / factor
        guard count >= 512 else { return nil }
        var pcm = [Double](repeating: 0, count: count)
        for i in pcm.indices {
            for j in 0..<factor { pcm[i] += Double(samples[i * factor + j]) / Double(factor) }
        }
        guard pcm.allSatisfy(\.isFinite), sqrt(pcm.reduce(0) { $0 + $1 * $1 } / Double(count)) >= floor else { return nil }
        let size = count / 2, maximum = min(size - 1, Int(rate / 55)), minimum = max(2, Int(rate / 1800))
        guard maximum > minimum else { return nil }
        var values = [Double](repeating: 1, count: maximum + 1), sum = 0.0
        for lag in 1...maximum {
            var difference = 0.0
            for i in 0..<size { let d = pcm[i] - pcm[i + lag]; difference += d * d }
            sum += difference
            values[lag] = sum > 0 ? difference * Double(lag) / sum : 1
        }
        var lag = minimum
        while lag < maximum {
            if values[lag] < 0.12 {
                while lag < maximum && values[lag + 1] < values[lag] { lag += 1 }
                let a = values[lag - 1], b = values[lag], c = values[min(maximum, lag + 1)]
                let denominator = a + c - 2 * b
                let shift = denominator == 0 ? 0 : max(-0.5, min(0.5, (a - c) / (2 * denominator)))
                return Int((69 + 12 * log2(rate / (Double(lag) + shift) / 440)).rounded())
            }
            lag += 1
        }
        return nil
    }
}
