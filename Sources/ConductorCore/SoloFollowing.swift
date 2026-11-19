import Foundation
import Accelerate

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
    public let writtenCadenzas: [PassageRange]
    public let cadenzas: [CompiledCadenza]
    public let end: Double

    public init(score: MusicXMLScore, solo: MusicXMLStaffID, waits: [WaitPoint], freePassages requested: [PassageRange] = [], cadenzas: [CompiledCadenza],
                followWrittenCadenzas: Bool = false) throws {
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
        end = score.endQuarter
        var gaps = requested.sorted { $0.start < $1.start }
        let accompaniment = score.staves.filter { $0.id != solo }.flatMap(\.soundingIntervals)
        for (index, range) in gaps.enumerated() {
            guard range.start >= 0, range.end <= end, range.start < range.end else {
                throw MusicalError("Choose a start and a later return within the score.")
            }
            guard index == 0 || gaps[index - 1].end < range.start else {
                throw MusicalError("Free passages must be separate. Combine adjoining passages.")
            }
            guard notes.contains(where: { $0.startQuarter >= range.start && $0.startQuarter < range.end }) else {
                throw MusicalError("Include a written solo entrance in the free passage.")
            }
            guard !accompaniment.contains(where: { $0.startQuarter < range.end - 1e-7 && $0.endQuarter > range.start + 1e-7 }) else {
                throw MusicalError("Choose a solo passage where the orchestra rests. The return may be its next entrance.")
            }
        }
        let inferred = followWrittenCadenzas ? Self.writtenRanges(notes: notes, accompaniment: accompaniment, marks: score.cadenzaDirectionQuarters) : []
        func overlaps(_ pedal: CompiledCadenza, _ range: PassageRange) -> Bool {
            pedal.startQuarter < range.end && pedal.returnQuarter > range.start
        }
        let automatic = inferred.filter { range in
            guard !requested.contains(where: { $0.start < range.end && $0.end > range.start }) else { return false }
            // A saved stop for this same return can be followed automatically.
            // A different pedal instruction in the passage keeps manual control.
            return cadenzas.filter { overlaps($0, range) }.allSatisfy {
                $0.startQuarter >= range.start - 1e-7 && abs($0.returnQuarter - range.end) < 1e-7
            }
        }
        writtenCadenzas = automatic
        self.cadenzas = cadenzas.filter { pedal in !automatic.contains { overlaps(pedal, $0) } }
        gaps += writtenCadenzas
        gaps.sort { $0.start < $1.start }
        for cadenza in self.cadenzas {
            gaps = gaps.flatMap { gap -> [PassageRange] in
                guard cadenza.startQuarter < gap.end, cadenza.returnQuarter > gap.start else { return [gap] }
                return [PassageRange(start: gap.start, end: min(gap.end, cadenza.startQuarter)),
                        PassageRange(start: max(gap.start, cadenza.returnQuarter), end: gap.end)]
                    .filter { $0.end > $0.start }
            }
        }
        freePassages = gaps.filter { gap in
            staff.notes.contains { $0.startQuarter >= gap.start && $0.startQuarter < gap.end }
        }
    }

    /// Infer an unlabelled cadenza from a sustained orchestral rest containing
    /// a written phrase. A later sounding interval supplies the exact re-entry.
    private static func writtenRanges(notes: [MIDINote], accompaniment: [MusicXMLSoundingInterval],
                                      marks: Set<Double>) -> [PassageRange] {
        var ranges: [PassageRange] = []
        var release = 0.0
        var firstNote = notes.startIndex
        for entrance in accompaniment.sorted(by: { $0.startQuarter < $1.startQuarter }) {
            defer { release = max(release, entrance.endQuarter) }
            let gap = entrance.startQuarter - release
            guard gap > 1e-7 else { continue }
            let mark = marks.filter { $0 >= release - 1e-7 && $0 < entrance.startQuarter - 1e-7 }.min()
            let firstBarline = ceil((release - 1e-7) / 4) * 4
            if mark != nil || entrance.startQuarter >= firstBarline + 8 - 1e-7 {
                let start = max(mark ?? release, release)
                while firstNote < notes.count && notes[firstNote].startQuarter < start - 1e-7 { firstNote += 1 }
                let confirmingNote = mark == nil ? firstNote + 2 : firstNote
                if confirmingNote < notes.count && notes[confirmingNote].startQuarter < entrance.startQuarter - 1e-7 {
                    ranges.append(PassageRange(start: start, end: entrance.startQuarter))
                }
            }
        }
        return ranges
    }
}

public enum FollowingStatus: String, Sendable {
    case following = "Following"
    case holding = "Holding tempo"
    case waiting = "Waiting for you"
    case lost = "Tracking lost"
    case cadenza = "Cadenza · use pedal"
    case finished = "Finished"
}

/// Stateful, local phrase matching. Only fresh attacks advance repeated pitches.
/// Missed/wrong notes are tolerated by searching ahead; time is a prior, never a
/// command to advance a freely played passage. No audio or UI dependencies.
public struct SoloTracker: Codable, Sendable {
    public private(set) var index: Int?
    public private(set) var lastMatch = -Double.infinity
    public private(set) var lastAttack = -Double.infinity
    public private(set) var releasedAt: Double?
    public private(set) var rate = 1.0
    private var previousPitch: Int?
    private var candidatePitch: Int?
    private var candidateCount = 0
    private var silentFrames = 0
    private struct Anchor: Codable, Sendable { let scoreTime: Double; let hostTime: Double }
    private var anchors: [Anchor] = []
    private var candidateSince = 0.0
    private var previousFrameTime: Double?
    private var searchStart = 0
    // Optional so diagnostics saved before confidence tracking remain readable.
    private var tempoConfirmed: Bool? = false
    // A short phrase proposing a large change needs another attack to confirm it.
    // Optional for compatibility with saved diagnostics from earlier versions.
    private var pendingTempoRate: Double?
    // Written note whose lead-in is sounding. Only its resolution advances the score.
    private var gracePrincipal: Int?
    private var graceResolutionTime: Double?
    private var unmatchedAttacks: [Int]?
    public func isPlayingGrace(at time: Double) -> Bool {
        gracePrincipal != nil && time - lastMatch < FollowingTempo.recentMatchWindow
    }
    public var hasReliableTempo: Bool { tempoConfirmed ?? (anchors.count >= 3) }

    public init() {}
    public func validForReplay(noteCount: Int) -> Bool {
        let validIndex = index.map { $0 >= 0 && $0 < noteCount } ?? true
        let validPitches = [previousPitch, candidatePitch].allSatisfy { $0.map { (0...127).contains($0) } ?? true }
        let validGrace = gracePrincipal.map { (0..<noteCount).contains($0) } ?? true
        let validPhrase = unmatchedAttacks.map { $0.count <= 4 && $0.allSatisfy { (0...127).contains($0) } } ?? true
        return validPhrase && validIndex && validGrace && (graceResolutionTime?.isFinite ?? true) &&
            validPitches && searchStart >= 0 && searchStart <= noteCount &&
            candidateCount >= 0 && candidateCount < Int.max / 2 && silentFrames >= 0 && silentFrames < Int.max / 2 &&
            rate.isFinite && (0.1...4).contains(rate) && candidateSince.isFinite &&
            (pendingTempoRate.map { $0.isFinite && (0.1...4).contains($0) } ?? true) &&
            (lastMatch.isFinite || lastMatch == -.infinity) && (lastAttack.isFinite || lastAttack == -.infinity) &&
            (releasedAt?.isFinite ?? true) && (previousFrameTime?.isFinite ?? true) &&
            anchors.count <= 10000 && anchors.allSatisfy { $0.hostTime.isFinite && $0.scoreTime.isFinite }
    }

    public mutating func reset(notes: [MIDINote], quarter: Double, preservingSound: Bool = false) {
        let sounding = previousPitch, candidate = candidatePitch, count = candidateCount, since = candidateSince
        self = SoloTracker()
        if preservingSound { previousPitch = sounding; candidatePitch = candidate; candidateCount = count; candidateSince = since }
        searchStart = notes.firstIndex { $0.endQuarter > quarter + 1e-7 } ?? notes.count
    }

    public mutating func beginAccompaniedPhrase(scoreTime: Double, tolerance: Double) {
        pendingTempoRate = nil
        // The return starts at planned tempo. Keep the recognized attack so a
        // sustained return note is not mistaken for a second entrance.
        // Let a steady, in-tolerance lead-in guide the gradual adjustment after
        // the downbeat. A freely stretched or uneven lead-in supplies no pace.
        let steady = anchors.count >= 3 && anchors.allSatisfy { anchor in
            abs((lastAttack - anchor.hostTime) * rate - (scoreTime - anchor.scoreTime)) < 0.04
        }
        tempoConfirmed = steady && abs(rate - 1) <= tolerance
        if !hasReliableTempo { rate = 1 }
        anchors = [Anchor(scoreTime: scoreTime, hostTime: lastAttack)]
    }

    @discardableResult
    public mutating func observe(pitch: Int?, time: Double, notes: [MIDINote], expectedQuarter: Double,
                                 free: Bool, midi: MIDIFile, rearticulated: Bool = false,
                                 throughQuarter: Double = .infinity) -> Int? {
        let frameInterval = previousFrameTime.map { min(0.04, max(0, time - $0)) } ?? 0
        previousFrameTime = time
        guard let pitch else {
            silentFrames += 1
            if silentFrames >= 2 { previousPitch = nil; if releasedAt == nil { releasedAt = time } }
            candidatePitch = nil; candidateCount = 0
            return nil
        }
        silentFrames = 0
        if candidatePitch == pitch { candidateCount += 1 } else { candidatePitch = pitch; candidateCount = 1; candidateSince = time - frameInterval / 2 }
        guard candidateCount >= 2 else { return nil }
        let repeatedAccent = previousPitch == pitch && rearticulated
        let attack = previousPitch != pitch || repeatedAccent
        previousPitch = pitch
        let next = max(searchStart, (index ?? (searchStart - 1)) + 1)
        if let principal = gracePrincipal {
            let note = notes[principal]
            if isPlayingGrace(at: time), note.startQuarter <= throughQuarter + 1e-7 {
                if pitch == note.pitch, attack {
                    // The ornament has no metrical duration. Establish the next
                    // phrase from the principal rather than fitting across it.
                    lastAttack = candidateSince
                    anchors = [Anchor(scoreTime: midi.seconds(atQuarter: note.startQuarter), hostTime: lastAttack)]
                    unmatchedAttacks = nil
                    index = principal; lastMatch = time; releasedAt = nil; gracePrincipal = nil
                    graceResolutionTime = lastAttack
                    return principal
                }
                if note.gracePitches?.contains(pitch) == true {
                    lastMatch = time; releasedAt = nil
                    return nil
                }
            }
            gracePrincipal = nil
        }

        if !attack, let index, notes[index].pitch == pitch {
            lastMatch = time; releasedAt = nil
            return nil
        }
        guard attack else { return nil }
        let onset = repeatedAccent ? time : candidateSince
        let lower = !free && !hasReliableTempo ? searchStart : next
        var candidates = Array(next..<min(notes.count, next + (free ? 3 : 8)))
        if !free {
            // Reacquire near the accompaniment, including behind a doubtful
            // match. A pitch several beats ahead cannot establish a new pace.
            let expectedTime = midi.seconds(atQuarter: expectedQuarter)
            let beat = midi.seconds(atQuarter: expectedQuarter + 1) - expectedTime
            let window = max(0.18, min(0.6, beat * 0.75))
            let earliest = midi.quarter(atSeconds: expectedTime - window)
            let latest = midi.quarter(atSeconds: expectedTime + window)
            candidates = notes.indices.filter {
                $0 >= lower && notes[$0].startQuarter >= earliest && notes[$0].startQuarter <= latest
            }
            // A real long-note phrase can drift beyond that window before its
            // attacks confirm a pace. Preserve immediate sequential
            // evidence, while distant pitch-only jumps still need reacquisition.
            if let index, next == index + 1, next < notes.count, onset > lastAttack {
                let interval = midi.seconds(atQuarter: notes[next].startQuarter) - midi.seconds(atQuarter: notes[index].startQuarter)
                if (0.1...4).contains(interval / (onset - lastAttack)) { candidates.append(next) }
            }
        }
        // Skipping a missed note can recover position inside a solo. Jumping
        // straight to the shared entrance would start audible playback early.
        if free && throughQuarter.isFinite {
            candidates.removeAll { $0 != next && notes[$0].startQuarter >= throughQuarter - 1e-7 }
        }
        if repeatedAccent, let index, notes[index].pitch == pitch { candidates = candidates.filter { $0 == next } }
        // Prefer a written attack if the player is actually on that note.
        // Otherwise a nearby notated ornament identifies its specific principal,
        // even when that principal's pitch recurs later in the figure.
        let ordinary = candidates.filter { notes[$0].pitch == pitch && notes[$0].startQuarter <= throughQuarter + 1e-7 }
        let nearest = ordinary.min {
            free ? $0 < $1 : abs(notes[$0].startQuarter - expectedQuarter) < abs(notes[$1].startQuarter - expectedQuarter)
        }
        if let grace = Self.principalForGrace(in: candidates, notes: notes, pitch: pitch, next: next,
                                           quarter: expectedQuarter, through: throughQuarter, free: free, ordinary: nearest) {
            unmatchedAttacks = nil
            gracePrincipal = grace; lastMatch = time; releasedAt = nil
            tempoConfirmed = false; pendingTempoRate = nil
            return nil
        }
        // An accent on a held pitch can articulate its immediate repetition
        // or the next written ornament. Otherwise it refreshes the sounding note.
        if repeatedAccent, let index, notes[index].pitch == pitch,
           next == notes.count || notes[next].pitch != pitch {
            lastMatch = time; releasedAt = nil
            return nil
        }
        // The accompaniment can still be ahead just after a lengthened ornament.
        // For close repeated pitches, check the next attack against the interval
        // the soloist actually played before falling back to transport proximity.
        let sequential = !free && ordinary.count > 1 && ordinary.contains(next) &&
            continuesGracePhrase(at: onset, next: next, notes: notes, midi: midi)
        var recognized = sequential ? next : nearest
        if recognized == nil, free, throughQuarter.isFinite {
            recognized = recoverPhrase(pitch: pitch, notes: notes, next: next, through: throughQuarter)
            if recognized != nil { anchors = [] }
        }
        guard let match = recognized else {
            // An unrecognized pitch supplies no timing evidence. Keep the
            // previous phrase so the next correct attack can corroborate it.
            if !free { tempoConfirmed = false; pendingTempoRate = nil }
            return nil
        }
        unmatchedAttacks = nil
        // Reacquiring the same written note after a gap refreshes position
        // confidence. Its original onset still belongs to this phrase.
        if !free, match == index {
            lastMatch = time; releasedAt = nil
            return nil
        }
        // Position recovery is useful without being evidence of faster playing.
        // Start a new phrase after a skipped or backwards match; retain its last
        // trusted pace until subsequent attacks corroborate the new position.
        if !free, let index, match != index + 1 {
            anchors = []; tempoConfirmed = false; pendingTempoRate = nil; graceResolutionTime = nil
        }
        let scoreTime = midi.seconds(atQuarter: notes[match].startQuarter)
        // Estimate pace over a short phrase. A frame of onset jitter on a single
        // triplet should not drive the accompaniment all the way to its tempo limit.
        while anchors.count > (free ? 1 : 2) && onset - anchors[1].hostTime >= 1.2 { anchors.removeFirst() }
        anchors.append(Anchor(scoreTime: scoreTime, hostTime: onset))
        if onset - anchors[0].hostTime > 0.08 {
            let fit = Self.phraseFit(anchors[...])
            if free { rate = min(4, max(0.1, fit.rate)) }
            else {
                // An uneven entrance can stay in the fitting window after the player
                // has already established a new pulse. Four consecutive attacks can
                // confirm that pulse on their own, using the same timing checks.
                var phrase = fit
                if !phrase.consistent, anchors.count > 4 {
                    phrase = Self.phraseFit(anchors.suffix(4))
                }
                let fitted = phrase.rate
                let consistent = phrase.consistent
                // Keep small expressive changes responsive. Two intervals alone
                // cannot replace the established pulse with a markedly different
                // pace that would then persist through a long note or solo rest.
                // A fourth coherent attack, or a matching estimate on the next
                // attack of a sparse phrase, supplies the extra evidence.
                let largeChange = abs(fitted / rate - 1) > 0.12
                let corroborated = anchors.count >= 4 ||
                    pendingTempoRate.map { abs(fitted / $0 - 1) <= 0.05 } == true
                tempoConfirmed = consistent && (!largeChange || corroborated)
                pendingTempoRate = consistent && !hasReliableTempo ? fitted : nil
                if hasReliableTempo { rate = fitted }
            }
        }
        index = match; lastMatch = time; lastAttack = onset; releasedAt = nil
        return match
    }

    /// After missing several notes, reacquire only a unique sequence of four
    /// fresh attacks within the remaining passage. Pauses carry no position.
    private mutating func recoverPhrase(pitch: Int, notes: [MIDINote], next: Int, through: Double) -> Int? {
        let phrase = Array((unmatchedAttacks ?? []).suffix(3)) + [pitch]
        unmatchedAttacks = phrase
        guard phrase.count == 4, Set(phrase).count >= 3, next + 3 < notes.count else { return nil }
        var match: Int?
        for end in (next + 3)..<notes.count {
            if notes[end].startQuarter > through + 1e-7 { break }
            if notes[(end - 3)...end].map(\.pitch) == phrase {
                guard match == nil else { return nil }
                match = end
            }
        }
        return match
    }

    private static func principalForGrace(in candidates: [Int], notes: [MIDINote], pitch: Int, next: Int,
                                       quarter: Double, through: Double, free: Bool, ordinary: Int?) -> Int? {
        let grace = candidates.filter { index in
            let note = notes[index]
            return index >= next && note.pitch != pitch && note.gracePitches?.contains(pitch) == true &&
                note.startQuarter <= through + 1e-7 && (free ? index == next : abs(note.startQuarter - quarter) <= 0.5)
        }.min { abs(notes[$0].startQuarter - quarter) < abs(notes[$1].startQuarter - quarter) }
        guard let grace, let ordinary else { return grace }
        if free { return ordinary <= grace ? nil : grace }
        return abs(notes[ordinary].startQuarter - quarter) < abs(notes[grace].startQuarter - quarter) ? nil : grace
    }

    private func continuesGracePhrase(at onset: Double, next: Int, notes: [MIDINote], midi: MIDIFile) -> Bool {
        guard let resolved = graceResolutionTime, onset - resolved <= 1.5, let index else { return false }
        let interval = midi.seconds(atQuarter: notes[next].startQuarter) - midi.seconds(atQuarter: notes[index].startQuarter)
        let played = (onset - lastAttack) * rate
        return abs(interval - played) <= min(0.15, max(0.05, interval * 0.35))
    }

    private static func phraseFit(_ phrase: ArraySlice<Anchor>) -> (rate: Double, consistent: Bool) {
        guard let first = phrase.first, let last = phrase.last else { return (1, false) }
        let count = Double(phrase.count)
        let meanHost = phrase.reduce(0) { $0 + ($1.hostTime - last.hostTime) } / count
        let meanScore = phrase.reduce(0) { $0 + ($1.scoreTime - last.scoreTime) } / count
        var covariance = 0.0, variance = 0.0
        for anchor in phrase {
            let dt = (anchor.hostTime - last.hostTime) - meanHost
            covariance += dt * ((anchor.scoreTime - last.scoreTime) - meanScore)
            variance += dt * dt
        }
        let fitted = covariance / variance
        guard phrase.count >= 3, last.hostTime - first.hostTime >= 0.6,
              fitted.isFinite, (0.1...4).contains(fitted) else { return (fitted, false) }
        let coherent = phrase.allSatisfy {
            abs(($0.hostTime - last.hostTime) * fitted - ($0.scoreTime - last.scoreTime)) <= 0.10
        } && zip(phrase, phrase.dropFirst()).allSatisfy { previous, current in
            let predicted = (current.scoreTime - previous.scoreTime) / fitted
            let observed = current.hostTime - previous.hostTime
            return predicted > 0 && abs(observed - predicted) <= max(0.04, predicted * 0.25)
        }
        return (fitted, coherent)
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
        if envelope > 0.0003 && rms < envelope * 0.25 { dipped = true }
        if dipped && rms > max(0.0002, envelope * 0.6) && time - lastAttack > 0.08 {
            dipped = false; lastAttack = time; return true
        }
        return false
    }
}

/// Smoothed bounded rate control. Uncertain or stale tracking holds the current
/// rate; only a trusted phrase may steer tempo or position within the user's limit.
public struct FollowingTempo: Codable, Sendable {
    public static let recentMatchWindow = 0.6
    public static let timingAllowance = 0.035
    public private(set) var rate = 1.0
    public init() {}
    public mutating func reset() { rate = 1 }
    public mutating func update(delta: Double, tolerance: Double, trackedRate: Double, phaseError: Double, age: Double, reliable: Bool = true) -> Double {
        let bound = min(0.75, max(0, tolerance))
        let target: Double
        if reliable && age < Self.recentMatchWindow {
            // A breath or slightly late attack is a position difference, not a
            // new tempo. Allow 35 ms of timing play, then recover gently with at
            // most four percentage points beyond the established phrase pace.
            let error = max(0, abs(phaseError) - Self.timingAllowance) * (phaseError < 0 ? -1.0 : 1.0)
            let correction = min(0.04, max(-0.04, error * 0.5))
            target = min(1 + bound, max(1 - bound, trackedRate + correction))
        }
        else { target = rate }
        rate += (target - rate) * (1 - exp(-max(0, delta) / 0.35))
        rate = min(1 + bound, max(1 - bound, rate))
        return rate
    }
}

/// A small YIN detector for one live analysis window; work runs off the audio tap.
public enum LivePitch {
    public static func detect(samples: [Float], sampleRate: Double, floor: Double = 0.003) -> Int? {
        guard sampleRate.isFinite, (4000...384000).contains(sampleRate) else { return nil }
        let factor = max(1, Int(sampleRate / 12000)), rate = sampleRate / Double(factor)
        let count = samples.count / factor
        guard count >= max(128, Int(rate * 0.04)) else { return nil }
        var pcm = [Double](repeating: 0, count: count)
        for i in pcm.indices {
            for j in 0..<factor { pcm[i] += Double(samples[i * factor + j]) / Double(factor) }
        }
        guard pcm.allSatisfy(\.isFinite) else { return nil }
        let mean = pcm.reduce(0, +) / Double(count)
        for i in pcm.indices { pcm[i] -= mean }
        guard sqrt(pcm.reduce(0) { $0 + $1 * $1 } / Double(count)) >= floor else { return nil }
        let size = count / 2, maximum = min(size - 1, Int(rate / 55)), minimum = max(2, Int(rate / 1800))
        guard maximum > minimum else { return nil }
        var values = [Double](repeating: 1, count: maximum + 1), sum = 0.0
        for lag in 1...maximum {
            var difference = 0.0
            pcm.withUnsafeBufferPointer { buffer in
                vDSP_distancesqD(buffer.baseAddress!, 1, buffer.baseAddress! + lag, 1, &difference, vDSP_Length(size))
            }
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
