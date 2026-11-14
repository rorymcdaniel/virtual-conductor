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
}

public struct FollowingRehearsalResult: Sendable {
    public let frames: Int
    public let matches: Int
    public let minimumRate: Double
    public let maximumRate: Double
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
              test.minimumMatches > 0, ["decisions", "audio"].contains(test.source) else {
            throw MusicalError("Invalid rehearsal case: \(test.name)")
        }
        let events = report.decisions.filter { $0.expectedQuarter >= test.fromQuarter && $0.expectedQuarter < test.toQuarter }
        guard let first = events.first, let last = events.last, last.time > first.time,
              events.allSatisfy({ !$0.free && $0.phase == "audio" }),
              !report.notices.contains(where: { $0.time > first.time && $0.time < last.time &&
                  ($0.reason.contains("discontinuity") || $0.reason.contains("pedal") || $0.reason.contains("stopped")) }) else {
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
        var position = report.midi.seconds(atQuarter: first.expectedQuarter), previous = first.time
        var minimum = Double.infinity, maximum = -Double.infinity, matches = 0, checked = 0
        let checkTime = report.decisions.first { $0.expectedQuarter >= test.checkFromQuarter }?.time ?? .infinity
        for observation in observations {
            let delta = observation.time - previous
            guard delta >= 0 && delta <= 0.25 else { throw MusicalError("Rehearsal observations contain a timing discontinuity.") }
            position += delta * controller.rate
            if tracker.observe(pitch: observation.pitch, time: observation.time, notes: report.notes,
                expectedQuarter: report.midi.quarter(atSeconds: position), free: false, midi: report.midi,
                rearticulated: observation.rearticulated) != nil { matches += 1 }
            let input = FollowingTempoInput.accompanied(delta: min(0.1, delta), tolerance: report.tolerance/100,
                tracker: tracker, notes: report.notes, midi: report.midi, scoreTime: position, time: observation.time)
            let rate = controller.update(input)
            if observation.time >= checkTime { minimum = min(minimum, rate); maximum = max(maximum, rate); checked += 1 }
            previous = observation.time
        }
        guard checked > 0 else { throw MusicalError("No observations in the assertion interval.") }
        return FollowingRehearsalResult(frames: observations.count, matches: matches, minimumRate: minimum,
            maximumRate: maximum, passed: minimum >= test.minimumRate - 1e-9 && maximum <= test.maximumRate + 1e-9 && matches >= test.minimumMatches)
    }
}
