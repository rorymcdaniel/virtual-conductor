import Foundation

public struct MusicXMLStaffID: Hashable, Codable, Sendable {
    public let partID: String
    public let staffNumber: Int

    public init(partID: String, staffNumber: Int) {
        self.partID = partID
        self.staffNumber = staffNumber
    }
}

public struct MusicXMLSoundingInterval: Equatable, Sendable {
    public let startQuarter: Double
    public let endQuarter: Double
}

public struct MusicXMLStaff: Equatable, Sendable {
    public let id: MusicXMLStaffID
    public let displayName: String
    public let soundingIntervals: [MusicXMLSoundingInterval]
    /// Concert pitches; -1 denotes a note unsuitable for monophonic following.
    public var notes: [MIDINote] = []
}

public struct MusicXMLMeasure: Equatable, Sendable {
    public let number: String
    public let startQuarter: Double
    public let endQuarter: Double
}

public enum MusicXMLUnsupportedCueReason: Equatable, Sendable {
    case pickup
    case nonFourFourMeter
    case changingMeter
    case repeatsOrJumps
    case unestablishedPlayback(String)

    public var message: String {
        switch self {
        case .pickup: "Pickup measures are not supported for cues."
        case .nonFourFourMeter: "Cues require a 4/4 time signature."
        case .changingMeter: "Changing time signatures are not supported for cues."
        case .repeatsOrJumps: "Repeats and jumps are not supported for cues."
        case .unestablishedPlayback(let detail): "Cue playback mapping is not established: \(detail)"
        }
    }
}

public enum MusicXMLReadError: Error, Equatable, LocalizedError, Sendable {
    case malformed(String)
    case unsupportedCue(MusicXMLUnsupportedCueReason)

    public var errorDescription: String? {
        switch self {
        case .malformed(let detail): "Invalid MusicXML: \(detail)"
        case .unsupportedCue(let reason): reason.message
        }
    }
}

public struct MusicXMLScore: Sendable {
    public let staves: [MusicXMLStaff]
    public let measures: [MusicXMLMeasure]
    public var endQuarter: Double { measures.last?.endQuarter ?? 0 }

    public init(data: Data) throws {
        let document = MusicXMLDocument()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = document
        guard parser.parse(), let root = document.root else {
            throw MusicXMLReadError.malformed(parser.parserError?.localizedDescription ?? "Missing score.")
        }
        if root.name == "score-timewise" {
            throw MusicXMLReadError.unsupportedCue(.unestablishedPlayback("Use an uncompressed score-partwise export."))
        }
        guard root.name == "score-partwise" else {
            throw MusicXMLReadError.malformed("Expected a score-partwise document.")
        }
        try root.checkPlaybackStructure()
        let definitions = root.child("part-list")?.children.filter { $0.name == "score-part" } ?? []
        let definitionIDs = definitions.compactMap { $0.attributes["id"] }
        guard Set(definitionIDs).count == definitionIDs.count else {
            throw MusicXMLReadError.unsupportedCue(.unestablishedPlayback("Duplicate part IDs."))
        }
        var parsedStaves: [MusicXMLStaff] = []
        var parsedMeasures: [MusicXMLMeasure] = []
        var partIDs: Set<String> = []
        for part in root.children where part.name == "part" {
            guard let id = part.attributes["id"], !id.isEmpty else { throw MusicXMLReadError.malformed("Missing part ID.") }
            guard partIDs.insert(id).inserted else {
                throw MusicXMLReadError.unsupportedCue(.unestablishedPlayback("Duplicate part IDs."))
            }
            let partName = definitions.first { $0.attributes["id"] == id }?.child("part-name")?.text ?? ""
            let name = partName.isEmpty ? id : partName
            var divisions: Double?
            var hasMeter = false
            var intervals: [Int: [MusicXMLSoundingInterval]] = [:]
            var pitches: [Int: [Int: Int]] = [:]
            var transposition: [Int: Int] = [:]
            var staffNumbers = [1]
            var activeTies: [MusicXMLTieKey: Int] = [:]
            let partMeasures = part.children.filter { $0.name == "measure" }
            if !parsedStaves.isEmpty, partMeasures.count != parsedMeasures.count {
                throw MusicXMLReadError.unsupportedCue(.unestablishedPlayback("Parts have different measure counts."))
            }
            for (index, measure) in partMeasures.enumerated() {
                let start = Double(index) * 4
                if parsedStaves.isEmpty {
                    parsedMeasures.append(MusicXMLMeasure(number: measure.attributes["number"] ?? "", startQuarter: start, endQuarter: start + 4))
                }
                var cursor = 0.0
                var extent = 0.0
                var previousOnset: Double?
                for element in measure.children {
                    switch element.name {
                    case "attributes":
                        for transpose in element.children where transpose.name == "transpose" {
                            let staff = Int(transpose.attributes["number"] ?? "0") ?? 0
                            guard let chromatic = Int(transpose.child("chromatic")?.text ?? "0"),
                                  let octave = Int(transpose.child("octave-change")?.text ?? "0"),
                                  (-48...48).contains(chromatic), (-4...4).contains(octave) else {
                                throw MusicXMLReadError.malformed("Invalid transposition.")
                            }
                            transposition[staff] = chromatic + octave * 12
                        }
                        if let value = element.child("divisions") { divisions = try value.positiveNumber() }
                        for time in element.children where time.name == "time" {
                            let beats = time.children.filter { $0.name == "beats" }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                            let beatTypes = time.children.filter { $0.name == "beat-type" }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                            guard beats == ["4"], beatTypes == ["4"], time.child("senza-misura") == nil else {
                                throw MusicXMLReadError.unsupportedCue(index == 0 ? .nonFourFourMeter : .changingMeter)
                            }
                            hasMeter = true
                        }
                        if let count = element.child("staves") {
                            for staff in 1...(try count.positiveInteger()) where !staffNumbers.contains(staff) {
                                staffNumbers.append(staff)
                            }
                        }
                    case "note", "forward", "backup":
                        guard let divisions, let duration = element.child("duration") else {
                            throw MusicXMLReadError.malformed("Missing divisions or duration.")
                        }
                        let length = try duration.positiveNumber() / divisions
                        guard length.isFinite, length > 0 else { throw MusicXMLReadError.malformed("Invalid note length.") }
                        let staff = try element.child("staff")?.positiveInteger() ?? 1
                        if !staffNumbers.contains(staff) { staffNumbers.append(staff) }
                        let isChord = element.child("chord") != nil
                        let onset: Double
                        if isChord {
                            guard let previousOnset else { throw MusicXMLReadError.malformed("Chord has no preceding note.") }
                            onset = previousOnset
                        } else {
                            onset = cursor
                        }
                        if element.name == "note" {
                            if element.child("rest") == nil, element.child("cue") == nil {
                                let key = MusicXMLTieKey(staff: staff, voice: element.child("voice")?.text ?? "1", pitch: try element.pitchKey())
                                let ties = element.children.filter { $0.name == "tie" }.compactMap { $0.attributes["type"] }
                                let intervalIndex: Int
                                if ties.contains("stop") {
                                    let candidates = activeTies.filter { candidate, index in
                                        candidate.voice == key.voice && candidate.pitch == key.pitch
                                            && abs((intervals[candidate.staff]?[index].endQuarter ?? -.infinity) - (start + onset)) < 1e-9
                                    }
                                    let origin: MusicXMLTieKey
                                    if candidates[key] != nil {
                                        origin = key
                                    } else if candidates.count == 1, let candidate = candidates.keys.first {
                                        origin = candidate
                                    } else if candidates.count > 1 {
                                        throw MusicXMLReadError.unsupportedCue(.unestablishedPlayback("Ambiguous cross-staff tie."))
                                    } else {
                                        throw MusicXMLReadError.malformed("Tie stop has no contiguous start.")
                                    }
                                    guard let existing = activeTies.removeValue(forKey: origin), let interval = intervals[origin.staff]?[existing] else {
                                        throw MusicXMLReadError.malformed("Tie stop has no start.")
                                    }
                                    if origin.staff == staff {
                                        intervalIndex = existing
                                        intervals[staff]?[existing] = MusicXMLSoundingInterval(startQuarter: interval.startQuarter, endQuarter: start + onset + length)
                                    } else {
                                        intervalIndex = intervals[staff, default: []].count
                                        intervals[staff, default: []].append(MusicXMLSoundingInterval(startQuarter: start + onset, endQuarter: start + onset + length))
                                    }
                                } else {
                                    intervalIndex = intervals[staff, default: []].count
                                    intervals[staff, default: []].append(MusicXMLSoundingInterval(startQuarter: start + onset, endQuarter: start + onset + length))
                                }
                                if ties.contains("start") {
                                    guard activeTies[key] == nil else {
                                        throw MusicXMLReadError.unsupportedCue(.unestablishedPlayback("Overlapping ties for the same staff, voice, and pitch."))
                                    }
                                    activeTies[key] = intervalIndex
                                }
                                pitches[staff, default: [:]][intervalIndex] = element.concertPitch(transpose: transposition[staff] ?? transposition[0] ?? 0)
                            }
                            previousOnset = onset
                        } else {
                            previousOnset = nil
                        }
                        if !isChord { cursor += element.name == "backup" ? -length : length }
                        guard cursor >= -1e-9 else { throw MusicXMLReadError.malformed("Backup moves before the measure start.") }
                        extent = max(extent, cursor, onset + (element.name == "note" ? length : 0))
                    default: break
                    }
                }
                guard hasMeter else {
                    throw MusicXMLReadError.unsupportedCue(.unestablishedPlayback("Missing initial time signature."))
                }
                if index == 0, extent > 0, extent < 4 - 1e-9 {
                    throw MusicXMLReadError.unsupportedCue(.pickup)
                }
                if extent > 0, abs(extent - 4) > 1e-9 {
                    throw MusicXMLReadError.unsupportedCue(.unestablishedPlayback("Measure \(measure.attributes["number"] ?? "") does not span four quarters."))
                }
            }
            guard activeTies.isEmpty else {
                throw MusicXMLReadError.unsupportedCue(.unestablishedPlayback("A tie has no ending note."))
            }
            for staff in staffNumbers {
                let displayName = staffNumbers.count == 1 ? name : "\(name) (staff \(staff))"
                let sounding = intervals[staff] ?? []
                let notes = sounding.enumerated().map { index, interval in
                    MIDINote(pitch: pitches[staff]?[index] ?? -1, startQuarter: interval.startQuarter, endQuarter: interval.endQuarter)
                }.sorted { $0.startQuarter < $1.startQuarter }
                parsedStaves.append(MusicXMLStaff(id: MusicXMLStaffID(partID: id, staffNumber: staff), displayName: displayName, soundingIntervals: sounding, notes: notes))
            }
        }
        guard !parsedStaves.isEmpty, !parsedMeasures.isEmpty else {
            throw MusicXMLReadError.malformed("Missing parts or measures.")
        }
        staves = parsedStaves
        measures = parsedMeasures
    }
}

private struct MusicXMLTieKey: Hashable {
    let staff: Int
    let voice: String
    let pitch: String
}

private final class MusicXMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [MusicXMLNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func child(_ name: String) -> MusicXMLNode? { children.first { $0.name == name } }

    func checkPlaybackStructure() throws {
        let repeatElements = ["repeat", "ending", "segno", "coda", "measure-repeat", "beat-repeat"]
        let jumpAttributes = ["dacapo", "dalsegno", "tocoda", "fine", "segno", "coda", "forward-repeat"]
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let jumpDirective = #"^(?:(?:d\.?\s*[cs]\.?|da\s+capo|dal\s+segno)(?:\s+al\s+(?:fine|coda))?|to\s+coda|fine)\.?$"#
        if repeatElements.contains(name)
            || (name == "sound" && jumpAttributes.contains { attributes[$0] != nil })
            || (name == "words" && words.range(of: jumpDirective, options: .regularExpression) != nil) {
            throw MusicXMLReadError.unsupportedCue(.repeatsOrJumps)
        }
        if name == "grace"
            || (name == "measure" && attributes["non-controlling"] == "yes")
            || (name == "note" && ["attack", "release"].contains { attributes[$0] != nil && Double(attributes[$0]!) != 0 })
            || (name == "tremolo" && ["start", "stop"].contains(attributes["type"] ?? "")) {
            throw MusicXMLReadError.unsupportedCue(.unestablishedPlayback("Unsupported timing in \(name)."))
        }
        for child in children { try child.checkPlaybackStructure() }
    }

    func pitchKey() throws -> String {
        if let pitch = child("pitch"), let step = pitch.child("step")?.text,
           ["A", "B", "C", "D", "E", "F", "G"].contains(step),
           let octaveText = pitch.child("octave")?.text, let octave = Int(octaveText),
           let alter = Double(pitch.child("alter")?.text ?? "0"), alter.isFinite {
            return "\(step)|\(octave)|\(alter)"
        }
        if let unpitched = child("unpitched") {
            return "\(child("instrument")?.attributes["id"] ?? "")|\(unpitched.child("display-step")?.text ?? "")|\(unpitched.child("display-octave")?.text ?? "")"
        }
        throw MusicXMLReadError.malformed("Note has no pitch or rest.")
    }

    func concertPitch(transpose: Int) -> Int {
        guard let pitch = child("pitch"), let step = pitch.child("step")?.text,
              let semitone = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][step],
              let octave = Int(pitch.child("octave")?.text ?? ""), (-1...9).contains(octave),
              let alter = Double(pitch.child("alter")?.text ?? "0"), alter.isFinite,
              abs(alter) <= 12, alter.rounded() == alter else { return -1 }
        let value = (octave + 1) * 12 + semitone + Int(alter) + transpose
        return (0...127).contains(value) ? value : -1
    }


    func positiveNumber() throws -> Double {
        guard let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite, number > 0 else {
            throw MusicXMLReadError.malformed("Invalid \(name).")
        }
        return number
    }

    func positiveInteger() throws -> Int {
        guard let number = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), number > 0 else {
            throw MusicXMLReadError.malformed("Invalid \(name).")
        }
        return number
    }
}

private final class MusicXMLDocument: NSObject, XMLParserDelegate {
    var root: MusicXMLNode?
    private var stack: [MusicXMLNode] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let node = MusicXMLNode(name: elementName, attributes: attributeDict)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        stack.removeLast()
    }
}
