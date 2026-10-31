import Foundation
import ConductorCore

/// Derived from the audio transport snapshot; no independent clock or retained cue state.
struct LongRestDisplay: Equatable {
    let counter: String?
    let cueBeat: Int?

    init(snapshot: ConductorSnapshot, schedule: LongRestSchedule?) {
        guard let schedule, let timing = snapshot.timing,
              [.running, .paused, .interrupted].contains(snapshot.state),
              snapshot.time.isFinite, snapshot.time >= timing.prepSeconds,
              snapshot.time < timing.musicalEnd else {
            counter = nil; cueBeat = nil; return
        }
        var quarter = timing.midi.quarter(atSeconds: snapshot.time - timing.prepSeconds)
        // Tempo conversion can land a few ulps before an exact musical boundary.
        let boundaries = schedule.runs.flatMap { run in
            run.fullRestMeasures.map(\.startQuarter) + [run.endQuarter] +
                (run.cue.map { [$0.quarter, $0.quarter + 1] } ?? [])
        }
        if let boundary = boundaries.first(where: { abs($0 - quarter) < 1e-9 }) { quarter = boundary }
        if let progress = schedule.progress(atQuarter: quarter) {
            counter = "\(progress.currentMeasure)/\(progress.run.fullMeasureCount)"
        } else { counter = nil }
        // A beat-wide cue remains visible for an on-beat entrance after its rest ends.
        let cue = schedule.runs.compactMap(\.cue).first { $0.quarter <= quarter && quarter < $0.quarter + 1 }
        cueBeat = snapshot.state == .running ? cue.map { Int($0.beat) } : nil
    }
}
