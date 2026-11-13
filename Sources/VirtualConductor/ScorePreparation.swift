import Foundation
import CryptoKit
import ConductorCore

// The editable draft and on-disk format share the existing flat JSON schema.
struct FollowingConfiguration: Codable {
    var enabled = false
    var solo: MusicXMLStaffID?
    var waits: [WaitPoint] = []
    var freePassages: [PassageRange] = []

    init() {}
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try fields.decode(Bool.self, forKey: .enabled)
        solo = try fields.decodeIfPresent(MusicXMLStaffID.self, forKey: .solo)
        waits = try fields.decode([WaitPoint].self, forKey: .waits)
        freePassages = try fields.decodeIfPresent([PassageRange].self, forKey: .freePassages) ?? []
    }
}

/// Owns the validated score and the one current solo-staff selection.
struct ScorePreparation {
    struct Loaded: Sendable {
        let score: MusicXMLScore?
        fileprivate let identity: URL?
        let unavailable: String?
        fileprivate let document: Data?
        fileprivate let settingsKey: String
        fileprivate let keptTiming: Bool

        init(musicXML: URL?, identity: URL?, midi: MIDIFile, midiFingerprint: String, keptTiming: Bool = false) {
            self.keptTiming = keptTiming
            self.identity = (identity ?? musicXML)?.standardizedFileURL
            let data = musicXML.flatMap { try? Data(contentsOf: $0) }
            document = data
            let xmlHash = data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "no-xml"
            settingsKey = "following-v1-" + midiFingerprint + "-" + xmlHash
            guard musicXML != nil else {
                score = nil; unavailable = "A matching MuseScore MusicXML export is required."
                return
            }
            do {
                guard let data else { throw MusicalError("The MusicXML export could not be read. Prepare it again.") }
                let parsed = try MusicXMLScore(data: data)
                try Self.validateMapping(score: parsed, midi: midi)
                score = parsed; unavailable = nil
            } catch {
                score = nil; unavailable = error.localizedDescription
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

    private struct Accepted {
        let source: Loaded
        var following: FollowingConfiguration
    }

    private enum State {
        case empty, loading(previous: Accepted?), accepted(Accepted), failed
    }

    private var state = State.empty
    private var generation: UInt64 = 0
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var accepted: Accepted? {
        if case .accepted(let context) = state { return context }
        return nil
    }

    var score: MusicXMLScore? { accepted?.source.score }
    var staves: [MusicXMLStaff] { score?.staves ?? [] }
    var following: FollowingConfiguration { accepted?.following ?? FollowingConfiguration() }
    var selectedStaffID: MusicXMLStaffID? { following.solo }

    var unavailableReason: String? {
        switch state {
        case .empty: "A matching MuseScore MusicXML export is required."
        case .loading: "Reading matching MusicXML…"
        case .failed: "Load matching exports first."
        case .accepted(let context): context.source.unavailable
        }
    }

    mutating func beginLoading() -> UInt64 {
        generation &+= 1
        if case .loading = state { return generation }
        state = .loading(previous: accepted)
        return generation
    }

    mutating func finishLoading(_ loaded: Loaded, generation token: UInt64) {
        guard token == generation, case .loading(let previous) = state else { return }

        var following = FollowingConfiguration()
        if let score = loaded.score {
            if let data = defaults.data(forKey: loaded.settingsKey),
               let saved = try? JSONDecoder().decode(FollowingConfiguration.self, from: data) {
                following = saved
            }

            // Retention follows the source score; instructions follow the exact export bytes.
            if let previous, let identity = loaded.identity, identity == previous.source.identity,
               loaded.document == previous.source.document || loaded.keptTiming,
               score.staves == previous.source.score?.staves, score.measures == previous.source.score?.measures {
                following.solo = previous.following.solo
                if loaded.settingsKey != previous.source.settingsKey { persist(following, key: loaded.settingsKey) }
            }
            if !score.staves.contains(where: { $0.id == following.solo }) {
                following.solo = nil
            }
        }
        state = .accepted(Accepted(source: loaded, following: following))
    }

    mutating func failLoading(generation token: UInt64) {
        guard token == generation, case .loading = state else { return }
        state = .failed
    }

    mutating func selectStaff(_ id: MusicXMLStaffID?) {
        guard var context = accepted else { return }
        context.following.solo = validStaff(id)
        persist(context.following, key: context.source.settingsKey)
        state = .accepted(context)
    }

    mutating func saveFollowing(_ draft: FollowingConfiguration) throws {
        guard var context = accepted else { throw MusicalError("Load matching exports before saving following settings.") }
        var values = draft
        values.solo = validStaff(draft.solo)
        let data = try JSONEncoder().encode(values)
        defaults.set(data, forKey: context.source.settingsKey)
        context.following = values
        state = .accepted(context)
    }

    private func persist(_ values: FollowingConfiguration, key: String) {
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: key) }
    }

    private func validStaff(_ id: MusicXMLStaffID?) -> MusicXMLStaffID? {
        staves.contains(where: { $0.id == id }) ? id : nil
    }
}
