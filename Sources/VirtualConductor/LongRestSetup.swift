import ConductorCore

/// Derives long-rest cues from the current score without owning its selection.
struct LongRestSetup {
    private(set) var threshold = 8
    private(set) var schedule: LongRestSchedule?
    private(set) var availability = "Long-rest cues need a matching MuseScore MusicXML export."

    mutating func update(from preparation: ScorePreparation) {
        schedule = nil
        guard let score = preparation.score else {
            availability = "Long-rest cues · " + (preparation.unavailableReason ?? "Choose matching MusicXML.")
            return
        }
        guard let staff = preparation.selectedStaffID else {
            availability = "Choose your solo staff for long-rest cues."
            return
        }
        do {
            let result = try LongRestSchedule(score: score, staffID: staff, threshold: threshold)
            schedule = result
            availability = result.runs.isEmpty ? "No rests meet this threshold on the selected staff." : "Long-rest cues ready · \(result.runs.count) qualifying rest\(result.runs.count == 1 ? "" : "s")."
        } catch { availability = "Long-rest cues unavailable: \(error.localizedDescription)" }
    }

    mutating func setThreshold(_ value: Int, preparation: ScorePreparation) {
        guard value > 0 else { return }
        threshold = value
        update(from: preparation)
    }
}
