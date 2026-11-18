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
