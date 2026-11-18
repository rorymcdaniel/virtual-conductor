import ConductorCore
import Foundation

/// Transport positions always index the original WAV. Recognition uses the
/// edited musical timeline, and playback stretches the original to that pace.
struct PracticeTempo {
    let marks: [PracticeTempoMark]
    let boundaries: Set<Double>
    let planned: MIDIFile
    let timing: PerformanceTiming

    init(timing: PerformanceTiming, marks: [PracticeTempoMark], boundaries: Set<Double>) throws {
        self.timing = timing
        self.marks = marks.sorted { $0.quarter < $1.quarter }
        self.boundaries = boundaries
        planned = try timing.midi.applyingTempoMarks(marks, boundaries: boundaries)
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
        let locations = boundaries.union(local).union(planned.segments.map(\.quarter)).union([0])
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

    func nextMark(after q: Double) -> Double? {
        boundaries.union(marks.map(\.quarter)).filter { $0 > q && $0 < planned.endQuarter }.min()
    }

    func quarter(at position: Double) -> Double {
        if position < timing.leadSeconds { return timing.preparationStartQuarter }
        return timing.midi.quarter(atSeconds: timing.scoreTime(performanceSeconds: position))
    }

    func bpm(atQuarter q: Double) -> Double { planned.tempo(atQuarter: q) }

    func sourceRate(at position: Double) -> Double {
        guard !marks.isEmpty else { return 1 }
        let q = quarter(at: position)
        return bpm(atQuarter: q) / timing.midi.tempo(atQuarter: q)
    }
}
