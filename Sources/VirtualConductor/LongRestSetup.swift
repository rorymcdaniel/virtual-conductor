import Foundation
import ConductorCore

/// Session-only selection, bound to a known score and its linear export timeline.
struct LongRestSetup {
    struct Loaded: Sendable {
        let score: MusicXMLScore?
        let identity: URL?
        let unavailable: String?
        let document: Data?
        let keptTiming: Bool

        init(musicXML: URL?, identity: URL?, midi: MIDIFile, keptTiming: Bool = false) {
            self.keptTiming = keptTiming
            self.identity = identity?.standardizedFileURL
            guard let musicXML else {
                document = nil; score = nil; unavailable = "Long-rest cues need a matching MuseScore MusicXML export."
                return
            }
            let data = try? Data(contentsOf: musicXML)
            document = data
            do {
                guard let data else { throw MusicalError("The MusicXML export could not be read. Prepare it again.") }
                let parsed = try MusicXMLScore(data: data)
                try Self.validateMapping(score: parsed, midi: midi)
                score = parsed; unavailable = nil
            } catch {
                score = nil; unavailable = "Long-rest cues unavailable: \(error.localizedDescription)"
            }
        }

        static func validateMapping(score: MusicXMLScore, midi: MIDIFile) throws {
            let tolerance = 1.001 / Double(midi.ppqn)
            // MuseScore ends MIDI at the final articulated note-off, often just before
            // the notated barline. Accept that final-measure tail, never extra bars.
            guard midi.endQuarter <= score.endQuarter + tolerance,
                  midi.endQuarter > score.endQuarter - 4 + tolerance else {
                throw MusicalError("MusicXML and MIDI have different musical lengths. Prepare matching exports again.")
            }
            let written = Set(score.staves.flatMap(\.soundingIntervals).map(\.startQuarter)).sorted()
            let notes = midi.tracks.flatMap(\.noteEvents).sorted { $0.startQuarter < $1.startQuarter }
            var writtenIndex = 0, playedIndex = 0
            // Every written attack still needs an anchor on the MIDI timeline.
            // Additional rendered attacks must belong to a marked ornament.
            let writtenMatches = written.allSatisfy { onset in
                while playedIndex < notes.count && notes[playedIndex].startQuarter < onset - tolerance { playedIndex += 1 }
                return playedIndex < notes.count && notes[playedIndex].startQuarter <= onset + tolerance
            }
            let playedMatches = notes.allSatisfy { note in
                let onset = note.startQuarter
                while writtenIndex < written.count && written[writtenIndex] < onset - tolerance { writtenIndex += 1 }
                if writtenIndex < written.count && written[writtenIndex] <= onset + tolerance { return true }
                return score.ornamentAttacks.contains {
                    $0.pitch == note.pitch && onset >= $0.startQuarter - tolerance && onset < $0.endQuarter + tolerance
                }
            }
            guard writtenMatches && playedMatches else {
                throw MusicalError("MusicXML and MIDI note positions do not establish a matching linear timeline. Check that both exports use the same score and playback order. Some rendered ornaments cannot be mapped.")
            }
        }
    }

    private(set) var score: MusicXMLScore?
    private(set) var selectedStaffID: MusicXMLStaffID?
    private(set) var threshold = 8
    private(set) var schedule: LongRestSchedule?
    private(set) var availability = "Long-rest cues need a matching MuseScore MusicXML export."
    private var previous: Loaded?
    private var previousSelection: MusicXMLStaffID?
    private var generation: UInt64 = 0
    var staves: [MusicXMLStaff] { score?.staves ?? [] }

    mutating func beginLoading() -> UInt64 {
        generation &+= 1
        if score != nil { previousSelection = selectedStaffID }
        score = nil; selectedStaffID = nil; schedule = nil
        availability = "Reading matching score for long-rest cues…"
        return generation
    }

    mutating func finishLoading(_ loaded: Loaded, generation token: UInt64) {
        guard token == generation else { return }
        let sameScore = loaded.identity != nil && loaded.identity == previous?.identity &&
            (loaded.document == previous?.document || loaded.keptTiming) &&
            loaded.score?.staves == previous?.score?.staves && loaded.score?.measures == previous?.score?.measures
        score = loaded.score
        selectedStaffID = sameScore ? previousSelection : nil
        previous = loaded; previousSelection = selectedStaffID
        availability = loaded.unavailable ?? "Choose your solo staff for long-rest cues."
        rebuild()
    }

    mutating func failLoading(generation token: UInt64) {
        guard token == generation else { return }
        score = nil; selectedStaffID = nil; schedule = nil
        previous = nil; previousSelection = nil
        availability = "Long-rest cues unavailable until matching exports load."
    }

    mutating func selectStaff(_ id: MusicXMLStaffID?) {
        selectedStaffID = staves.contains(where: { $0.id == id }) ? id : nil
        previousSelection = selectedStaffID
        rebuild()
    }

    mutating func setThreshold(_ value: Int) {
        guard value > 0 else { return }
        threshold = value; rebuild()
    }

    private mutating func rebuild() {
        schedule = nil
        guard let score else { return }
        guard let selectedStaffID else { availability = "Choose your solo staff for long-rest cues."; return }
        do {
            let result = try LongRestSchedule(score: score, staffID: selectedStaffID, threshold: threshold)
            schedule = result
            availability = result.runs.isEmpty ? "No rests meet this threshold on the selected staff." : "Long-rest cues ready · \(result.runs.count) qualifying rest\(result.runs.count == 1 ? "" : "s")."
        } catch { availability = "Long-rest cues unavailable: \(error.localizedDescription)" }
    }
}
