import Foundation

public struct MusicalError: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct MIDINote: Equatable, Sendable {
    public let pitch: Int
    public let startQuarter: Double
    public let endQuarter: Double
    public init(pitch: Int, startQuarter: Double, endQuarter: Double) {
        self.pitch = pitch; self.startQuarter = startQuarter; self.endQuarter = endQuarter
    }
}

public struct MIDITrack: Equatable, Sendable {
    public let name: String
    public let notes: Int
    public let noteEvents: [MIDINote]
}

public struct TempoSegment: Equatable, Sendable {
    public let quarter: Double
    public let seconds: Double
    public let secondsPerQuarter: Double
}

/// A standard format 0/1 MIDI file with a single 4/4 musical timeline.
public struct MIDIFile: Sendable {
    public let ppqn: Int
    public let tracks: [MIDITrack]
    public let segments: [TempoSegment]
    public let endQuarter: Double
    public var duration: Double { seconds(atQuarter: endQuarter) }
    public var openingBPM: Double { 60 / segments[0].secondsPerQuarter }
    public var measures: Int { Int(ceil(endQuarter / 4)) }

    public init(data: Data) throws {
        var reader = MIDIReader(bytes: Array(data))
        guard try reader.tag() == "MThd" else { throw MusicalError("Choose a standard MIDI file.") }
        let headerLength = try reader.integer(4)
        guard headerLength >= 6 else { throw MusicalError("Invalid MIDI header.") }
        let format = try reader.integer(2), trackCount = try reader.integer(2), division = try reader.integer(2)
        guard format <= 1, division > 0, division & 0x8000 == 0 else {
            throw MusicalError("This prototype needs a format 0 or 1 MIDI file with musical beat timing.")
        }
        ppqn = division
        try reader.seek(8 + headerLength)
        var parsedTracks: [MIDITrack] = []
        // Assignment order preserves the browser's last tempo at a shared tick.
        var tempos: [Int: Int] = [0: 500_000]
        var lastTick = 0
        var nonCommonMeter = false
        for _ in 0..<trackCount {
            guard try reader.tag() == "MTrk" else { throw MusicalError("Invalid MIDI track.") }
            let length = try reader.integer(4)
            try reader.require(length)
            let end = reader.position + length
            reader.limit = end
            var tick = 0, running = 0, name = ""
            var events: [MIDINote] = []
            var active: [Int: Int] = [:]
            func finish(_ key: Int) {
                guard let index = active.removeValue(forKey: key) else { return }
                let note = events[index]
                events[index] = MIDINote(pitch: note.pitch, startQuarter: note.startQuarter, endQuarter: Double(tick) / Double(division))
            }
            while reader.position < end {
                let delta = try reader.vlq()
                let (nextTick, overflow) = tick.addingReportingOverflow(delta)
                guard !overflow else { throw MusicalError("Invalid MIDI event length.") }
                tick = nextTick
                var status = try reader.byte()
                if status < 128 {
                    guard running != 0 else { throw MusicalError("Invalid MIDI running status.") }
                    reader.position -= 1
                    status = running
                }
                if status == 255 {
                    let type = try reader.byte(), count = try reader.vlq()
                    let payload = Array(try reader.payload(count, message: "Incomplete MIDI metadata."))
                    switch type {
                    case 81:
                        guard count == 3 else { throw MusicalError("Invalid MIDI tempo.") }
                        let us = Int(payload[0]) * 65536 + Int(payload[1]) * 256 + Int(payload[2])
                        guard us > 0 else { throw MusicalError("MIDI tempo must be positive.") }
                        tempos[tick] = us
                    case 88:
                        guard count >= 2 else { throw MusicalError("Invalid MIDI meter.") }
                        if payload[0] != 4 || payload[1] != 2 { nonCommonMeter = true }
                    case 3: name = String(decoding: payload, as: UTF8.self)
                    default: break
                    }
                    if type == 47 { break }
                } else if status == 240 || status == 247 {
                    let count = try reader.vlq()
                    _ = try reader.payload(count, message: "Incomplete MIDI data.")
                    running = 0
                } else if status >= 128 && status < 240 {
                    running = status
                    let a = try reader.byte()
                    let kind = status >> 4
                    let b = (kind == 12 || kind == 13) ? 0 : try reader.byte()
                    guard a <= 127, b <= 127 else { throw MusicalError("Invalid MIDI channel event.") }
                    let key = (status & 15) * 128 + a
                    if kind == 9 && b > 0 {
                        finish(key)
                        active[key] = events.count
                        let quarter = Double(tick) / Double(division)
                        events.append(MIDINote(pitch: a, startQuarter: quarter, endQuarter: quarter))
                    } else if kind == 8 || (kind == 9 && b == 0) { finish(key) }
                } else { throw MusicalError("Unsupported MIDI event.") }
            }
            for key in Array(active.keys) { finish(key) }
            lastTick = max(lastTick, tick)
            parsedTracks.append(MIDITrack(name: name, notes: events.count, noteEvents: events))
            reader.limit = reader.bytes.count
            try reader.seek(end)
        }
        guard lastTick > 0 else { throw MusicalError("The MIDI file has no musical duration.") }
        guard !nonCommonMeter else { throw MusicalError("This first version conducts in 4/4 only. This file contains another meter.") }
        tracks = parsedTracks
        var previousTick = 0, previousUS = 500_000
        var elapsed = 0.0
        var timeline: [TempoSegment] = []
        for tick in tempos.keys.sorted() {
            let us = tempos[tick]!
            elapsed += Double(tick - previousTick) / Double(division) * Double(previousUS) / 1e6
            timeline.append(TempoSegment(quarter: Double(tick) / Double(division), seconds: elapsed, secondsPerQuarter: Double(us) / 1e6))
            previousTick = tick; previousUS = us
        }
        segments = timeline
        let raw = Double(lastTick) / Double(division), nearest = raw.rounded()
        endQuarter = abs(raw - nearest) <= 1.001 / Double(division) ? nearest : raw
        // A one-tick file may round to zero in the reference; reject it here
        // because a nonpositive score cannot produce a conducting position.
        guard endQuarter > 0 else { throw MusicalError("The MIDI file has no musical duration.") }
    }

    private func segment(at value: Double, key: KeyPath<TempoSegment, Double>) -> TempoSegment {
        var low = 0, high = segments.count
        while low + 1 < high {
            let middle = (low + high) / 2
            if segments[middle][keyPath: key] <= value { low = middle } else { high = middle }
        }
        return segments[low]
    }
    public func seconds(atQuarter quarter: Double) -> Double {
        let s = segment(at: quarter, key: \.quarter)
        return s.seconds + (quarter - s.quarter) * s.secondsPerQuarter
    }
    public func quarter(atSeconds seconds: Double) -> Double {
        let s = segment(at: seconds, key: \.seconds)
        return s.quarter + (seconds - s.seconds) / s.secondsPerQuarter
    }
    public func tempo(atSeconds seconds: Double) -> Double { 60 / segment(at: seconds, key: \.seconds).secondsPerQuarter }
}

private struct MIDIReader {
    let bytes: [UInt8]
    var position = 0
    var limit: Int
    init(bytes: [UInt8]) { self.bytes = bytes; limit = bytes.count }
    func require(_ count: Int, message: String = "Incomplete MIDI file.") throws {
        guard count >= 0, position <= limit, count <= limit - position else { throw MusicalError(message) }
    }
    mutating func seek(_ offset: Int) throws {
        guard offset >= 0, offset <= limit else { throw MusicalError("Incomplete MIDI file.") }
        position = offset
    }
    mutating func integer(_ count: Int) throws -> Int {
        try require(count)
        var value = 0
        for _ in 0..<count { value = value * 256 + Int(bytes[position]); position += 1 }
        return value
    }
    mutating func tag() throws -> String { String(decoding: try payload(4, message: "Incomplete MIDI file."), as: UTF8.self) }
    mutating func byte() throws -> Int {
        try require(1, message: "Incomplete MIDI event.")
        defer { position += 1 }
        return Int(bytes[position])
    }
    mutating func payload(_ count: Int, message: String) throws -> ArraySlice<UInt8> {
        try require(count, message: message)
        defer { position += count }
        return bytes[position..<(position + count)]
    }
    mutating func vlq() throws -> Int {
        var value = 0
        for _ in 0..<4 {
            let b = try byte(); value = value * 128 + (b & 127)
            if b & 128 == 0 { return value }
        }
        throw MusicalError("Invalid MIDI event length.")
    }
}
