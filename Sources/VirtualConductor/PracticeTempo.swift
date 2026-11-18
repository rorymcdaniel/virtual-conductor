import ConductorCore
import Foundation

/// Transport positions always index the original WAV. Recognition uses the
/// edited musical timeline, and playback stretches the original to that pace.
struct PracticeTempo {
    struct Edits: Codable {
        var marks: [PracticeTempoMark] = []
        var deleted: Set<Double> = []
    }

    let marks: [PracticeTempoMark]
    let deleted: Set<Double>
    let boundaries: Set<Double>
    private let remainingBoundaries: Set<Double>
    let planned: MIDIFile
    let timing: PerformanceTiming

    init(timing: PerformanceTiming, marks: [PracticeTempoMark], boundaries: Set<Double>, deleted: Set<Double> = []) throws {
        self.deleted = deleted
        self.timing = timing
        self.marks = marks.sorted { $0.quarter < $1.quarter }
        self.boundaries = boundaries
        remainingBoundaries = timing.midi.remainingTempoBoundaries(boundaries, deleted: deleted)
        planned = try timing.midi.applyingTempoMarks(marks, boundaries: boundaries, deleted: deleted)
    }

    struct Entry: Identifiable {
        enum Source: String { case score = "Score", practice = "Practice", playback = "Tempo change" }
        let quarter: Double
        let bpm: Double
        let source: Source
        var id: Double { quarter }
    }

    /// Include written markings even when they repeat the preceding BPM. Between
    /// markings, show each actual change rendered by the planned playback map.
    var entries: [Entry] {
        let local = Set(marks.map(\.quarter))
        let locations = boundaries.subtracting(deleted).union(local).union(planned.segments.map(\.quarter)).union([0])
        var result = [Entry]()
        for q in locations.sorted() where q >= 0 && q < planned.endQuarter {
            let bpm = bpm(atQuarter: q)
            let source: Entry.Source = local.contains(q) ? .practice : boundaries.contains(q) || q == 0 ? .score : .playback
            if source != .playback || result.last?.bpm != bpm {
                result.append(Entry(quarter: q, bpm: bpm, source: source))
            }
        }
        return result
    }

    var edits: Edits { Edits(marks: marks, deleted: deleted) }

    func hasFollowingSteps(_ entry: Entry) -> Bool {
        let stop = nextMark(after: entry.quarter) ?? planned.endQuarter
        return timing.midi.segments.contains {
            $0.quarter > entry.quarter && $0.quarter < stop && !deleted.contains($0.quarter)
        }
    }

    func deleting(_ entry: Entry, includingTempoSteps: Bool) -> Edits {
        guard entry.quarter > 0 else { return edits }
        var positions: Set<Double> = [entry.quarter]
        if includingTempoSteps {
            let stop = nextMark(after: entry.quarter) ?? planned.endQuarter
            // Include redundant and currently overridden steps too, so removing
            // a practice marking cannot uncover the ramp being deleted.
            for segment in timing.midi.segments where segment.quarter > entry.quarter && segment.quarter < stop {
                positions.insert(segment.quarter)
            }
        }
        let scoreLocations = boundaries.union(timing.midi.segments.map(\.quarter))
        return Edits(marks: marks.filter { !positions.contains($0.quarter) },
                     deleted: deleted.union(positions.intersection(scoreLocations)))
    }

    func nextMark(after q: Double) -> Double? {
        remainingBoundaries.union(marks.map(\.quarter)).filter { $0 > q && $0 < planned.endQuarter }.min()
    }

    func quarter(at position: Double) -> Double {
        if position < timing.leadSeconds { return timing.preparationStartQuarter }
        return timing.midi.quarter(atSeconds: timing.scoreTime(performanceSeconds: position))
    }

    func bpm(atQuarter q: Double) -> Double { planned.tempo(atQuarter: q) }

    func sourceRate(at position: Double) -> Double {
        guard !marks.isEmpty || !deleted.isEmpty else { return 1 }
        let q = quarter(at: position)
        return bpm(atQuarter: q) / timing.midi.tempo(atQuarter: q)
    }
}
