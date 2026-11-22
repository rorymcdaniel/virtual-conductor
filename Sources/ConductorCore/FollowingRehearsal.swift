import Foundation

/// A private local regression case. The manifest and source reports stay outside
/// Git; expectations are chosen from the known musical behavior of the passage.
public struct FollowingRehearsalCase: Codable, Sendable {
    public let name: String
    public let report: String
    public let source: String
    public let fromQuarter: Double
    public let toQuarter: Double
    public let checkFromQuarter: Double
    public let startingRate: Double
    public let minimumRate: Double
    public let maximumRate: Double
    public let minimumMatches: Int
    public let maximumMedianAttackErrorBeats: Double?
}

public struct FollowingRehearsalResult: Sendable {
    public let frames: Int
    public let matches: Int
    public let minimumRate: Double
    public let maximumRate: Double
    public let medianAttackErrorBeats: Double?
    public let passed: Bool
}

public enum FollowingRehearsal {
    /// Continuous recognition + controller replay. The simulated accompaniment
    /// moves at each newly commanded rate, so a wrong match feeds back into the
    /// next position search just as it does live. This excludes physical latency
    /// and only accepts uninterrupted accompanied passages, not waits/cadenzas.
    public static func run(_ test: FollowingRehearsalCase, report: FollowingDiagnostic,
                           audioObservations: [SoloObservation]? = nil) throws -> FollowingRehearsalResult {
        guard [test.fromQuarter, test.toQuarter, test.checkFromQuarter, test.startingRate,
               test.minimumRate, test.maximumRate].allSatisfy(\.isFinite),
              test.fromQuarter <= test.checkFromQuarter, test.checkFromQuarter < test.toQuarter,
              (0.25...1.75).contains(test.startingRate), test.minimumRate <= test.maximumRate,
              test.minimumMatches > 0, ["decisions", "audio"].contains(test.source),
              test.maximumMedianAttackErrorBeats.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            throw MusicalError("Invalid rehearsal case: \(test.name)")
        }
        let events = report.decisions.filter { $0.expectedQuarter >= test.fromQuarter && $0.expectedQuarter < test.toQuarter }
        guard let first = events.first, let last = events.last, last.time > first.time,
              (report.decisions.first?.expectedQuarter ?? .infinity) <= test.fromQuarter,
              (report.decisions.last?.expectedQuarter ?? -.infinity) >= test.toQuarter,
              events.allSatisfy({ !$0.free && $0.resolvedPhase == .audio }),
              !report.notices.contains(where: { $0.time > first.time && $0.time < last.time &&
                  $0.interruptsReplay }) else {
            throw MusicalError("Rehearsal cases require an uninterrupted accompanied passage.")
        }
        let observations: [SoloObservation]
        if test.source == "audio" {
            guard let audioObservations, let audioStart = report.audioStart, let audioEnd = report.audioEnd,
                  audioStart <= first.time, audioEnd >= last.time else {
                throw MusicalError("The opted-in audio must cover the complete rehearsal case.")
            }
            observations = audioObservations.map {
                SoloObservation(pitch: $0.pitch, time: $0.time + audioStart, rearticulated: $0.rearticulated)
            }.filter { $0.time >= first.time && $0.time <= last.time }
        } else {
            observations = events.map { SoloObservation(pitch: $0.pitch, time: $0.time, rearticulated: $0.rearticulated) }
        }
        guard observations.count >= 3 else { throw MusicalError("Too little rehearsal evidence.") }
        var tracker = first.tracker, controller = FollowingTempo()
        _ = controller.update(delta: 100, tolerance: report.tolerance/100, trackedRate: test.startingRate, phaseError: 0, age: 0)
        var history = AccompanimentPositions()
        // Older reports may only have the recognition search position. Prefer
        // measured transport when playback commands bracket the first sample.
        for control in report.controls ?? [] where abs(control.time - first.time) <= 0.25 {
            history.record(host: control.time, score: control.scoreTime)
        }
        var position = history.scoreTime(at: first.time) ?? report.midi.seconds(atQuarter: first.expectedQuarter)
        history = AccompanimentPositions()
        var previous = first.time
        var minimum = Double.infinity, maximum = -Double.infinity, checked = 0
        var attackErrors: [Double] = []
        var matches = 0
        let checkTime = report.decisions.first { $0.expectedQuarter >= test.checkFromQuarter }?.time ?? .infinity
        for observation in observations {
            let delta = observation.time - previous
            guard delta >= 0 && delta <= 0.25 else { throw MusicalError("Rehearsal observations contain a timing discontinuity.") }
            position += delta * controller.rate
            history.record(host: observation.time, score: position)
            let quarter = report.midi.quarter(atSeconds: position)
            if let index = tracker.observe(pitch: observation.pitch, time: observation.time, notes: report.notes,
                expectedQuarter: quarter, free: false, midi: report.midi,
                rearticulated: observation.rearticulated, accompanimentAtOnset: history.scoreTime), observation.time >= checkTime {
                matches += 1
                if let atAttack = history.scoreTime(at: tracker.lastAttack) {
                    attackErrors.append(abs(report.midi.quarter(atSeconds: atAttack) - report.notes[index].startQuarter))
                }
            }
            let input = FollowingTempoInput.accompanied(delta: min(0.1, delta), tolerance: report.tolerance/100,
                tracker: tracker, notes: report.notes, midi: report.midi, scoreTime: position, time: observation.time)
            let rate = controller.update(input)
            if observation.time >= checkTime { minimum = min(minimum, rate); maximum = max(maximum, rate); checked += 1 }
            previous = observation.time
        }
        guard checked > 0 else { throw MusicalError("No observations in the assertion interval.") }
        attackErrors.sort()
        let count = attackErrors.count
        let median = count == 0 ? nil : (attackErrors[(count - 1) / 2] + attackErrors[count / 2]) / 2
        let timingPasses = test.maximumMedianAttackErrorBeats.map { count >= test.minimumMatches && (median ?? .infinity) <= $0 } ?? true
        return FollowingRehearsalResult(frames: observations.count, matches: matches, minimumRate: minimum,
            maximumRate: maximum, medianAttackErrorBeats: median, passed: timingPasses && matches >= test.minimumMatches &&
                minimum >= test.minimumRate - 1e-9 && maximum <= test.maximumRate + 1e-9)
    }
}
