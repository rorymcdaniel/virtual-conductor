import Foundation

public struct BeatTime: Codable, Equatable, Sendable {
    public var quarter: Double
    public var time: Double
    public init(quarter: Double, time: Double) { self.quarter = quarter; self.time = time }
}

public struct PassageRange: Codable, Equatable, Sendable {
    public let start: Double
    public let end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

public struct ObservedNote: Equatable, Sendable {
    public let pitch: Int
    public var start: Double
    public var end: Double
    public init(pitch: Int, start: Double, end: Double) { self.pitch = pitch; self.start = start; self.end = end }
}

public struct AnalysisResult: Equatable, Sendable {
    public let beats: [BeatTime]
    public let matched: Int
    public let total: Int
    public let warning: String
    public let origins: [BeatOrigin]
}

/// Offline interpretation only. None of these operations changes score or playback timing.
public enum Interpretation {
    public static func range(startMeasure: Int, startBeat: Int, endMeasure: Int, endBeat: Int, midi: MIDIFile) throws -> PassageRange {
        guard startMeasure >= 1, endMeasure >= 1, (1...4).contains(startBeat), (1...4).contains(endBeat) else {
            throw MusicalError("Use whole measure numbers and beats 1–4.")
        }
        let start = (Double(startMeasure) - 1) * 4 + Double(startBeat) - 1
        let end = (Double(endMeasure) - 1) * 4 + Double(endBeat) - 1
        guard end > start, end <= midi.endQuarter else { throw MusicalError("The end must follow the start and stay within the score.") }
        guard end - start <= 128 else { throw MusicalError("Choose a short passage of at most 32 measures for this first version.") }
        return PassageRange(start: start, end: end)
    }

    public static func detectNotes(samples: [Float], sampleRate: Double) -> [ObservedNote] {
        guard sampleRate.isFinite, (4000...384000).contains(sampleRate), samples.allSatisfy({ $0.isFinite }) else { return [] }
        var analyzer = SoloAudioAnalyzer(sampleRate: sampleRate)
        struct Run { let pitch: Int; var start: Double; var end: Double; var count: Int }
        var current: Run?, notes: [ObservedNote] = []
        func finish() {
            if let run = current, run.count >= 2 {
                notes.append(ObservedNote(pitch: run.pitch, start: max(0, run.start - 0.005), end: run.end))
            }
            current = nil
        }
        // Bound cancellation latency and temporary storage even for a two-minute take.
        for start in stride(from: 0, to: samples.count, by: 4096) {
            if Task.isCancelled { return [] }
            for observation in analyzer.process(Array(samples[start..<min(samples.count, start + 4096)])) {
                guard let pitch = observation.pitch else { finish(); continue }
                if current?.pitch != pitch || (observation.rearticulated && (current?.count ?? 0) >= 4) {
                    finish()
                    current = Run(pitch: pitch, start: observation.time, end: observation.time + 0.005, count: 1)
                } else {
                    current!.end = observation.time + 0.005; current!.count += 1
                }
            }
        }
        finish()
        return notes
    }

    public static func analyze(samples: [Float], sampleRate: Double, reference: [MIDINote], range: PassageRange) throws -> AnalysisResult {
        guard !samples.isEmpty, sampleRate.isFinite, sampleRate > 0, Double(samples.count) / sampleRate <= 120.1 else { throw MusicalError("Record a take up to two minutes long.") }
        let observed = detectNotes(samples: samples, sampleRate: sampleRate)
        try Task.checkCancellation()
        return try align(observed: observed, reference: reference, range: range, duration: Double(samples.count) / sampleRate)
    }

    public static func align(observed: [ObservedNote], reference: [MIDINote], range: PassageRange, duration: Double) throws -> AnalysisResult {
        let notes = reference.enumerated().filter { _, n in n.endQuarter > n.startQuarter && n.endQuarter > range.start && n.startQuarter < range.end }
            .sorted { a, b in a.element.startQuarter == b.element.startQuarter ? a.offset < b.offset : a.element.startQuarter < b.element.startQuarter }
            .map { _, n in MIDINote(pitch: n.pitch, startQuarter: max(range.start, n.startQuarter), endQuarter: min(range.end, n.endQuarter)) }
        guard notes.count >= 3 else { throw MusicalError("Choose a passage with at least three solo notes. Sustained notes alone do not reveal the beat timing.") }
        guard notes.count <= 500, observed.count <= 1500 else { throw MusicalError("Use a shorter, cleaner solo passage for analysis.") }
        for i in 1..<notes.count where notes[i].startQuarter < notes[i - 1].endQuarter - 0.05 { throw MusicalError("This MIDI part contains overlapping notes. Select the monophonic solo-horn part.") }
        guard observed.count >= 3 else { throw MusicalError("Not enough clear pitched notes were detected. Check the input level and record another take.") }
        func distance(_ a: Int, _ b: Int) -> Double { let d = abs(Double(a) - Double(b)); return d < 1 ? 0 : d.truncatingRemainder(dividingBy: 12) < 1 ? 0.65 : 2.5 }
        let rows = notes.count + 1, cols = observed.count + 1
        var cost = [Double](repeating: 0, count: rows * cols), path = [UInt8](repeating: 0, count: rows * cols)
        for i in 1..<rows { cost[i * cols] = Double(i) * 1.1; path[i * cols] = 1 }
        for j in 1..<cols { cost[j] = Double(j) * 1.1; path[j] = 2 }
        for i in 1..<rows {
            try Task.checkCancellation()
            for j in 1..<cols {
                let candidates = [cost[(i - 1) * cols + j - 1] + distance(notes[i - 1].pitch, observed[j - 1].pitch), cost[(i - 1) * cols + j] + 1.1, cost[i * cols + j - 1] + 1.1]
                var move = 0
                for k in 1..<3 where candidates[k] < candidates[move] { move = k }
                cost[i * cols + j] = candidates[move]; path[i * cols + j] = UInt8(move)
            }
        }
        var matched: [(MIDINote, ObservedNote)] = [], i = notes.count, j = observed.count
        while i > 0 || j > 0 {
            switch path[i * cols + j] {
            case 0:
                if distance(notes[i - 1].pitch, observed[j - 1].pitch) < 1 { matched.append((notes[i - 1], observed[j - 1])) }
                i -= 1; j -= 1
            case 1: i -= 1
            default: j -= 1
            }
        }
        matched.reverse()
        guard matched.count >= 3, Double(matched.count) / Double(notes.count) >= 0.7, Double(matched.count) / Double(observed.count) >= 0.6 else { throw MusicalError("The take could not be aligned reliably. Check the selected solo part and boundaries, or try a shorter passage.") }
        var anchors = matched.map { BeatTime(quarter: $0.0.startQuarter, time: $0.1.start) }
        let last = matched.last!
        anchors.append(BeatTime(quarter: last.0.endQuarter, time: last.1.end))
        var beats: [BeatTime] = [], q = range.start
        while q <= range.end {
            var a = anchors[0], b = anchors[1]
            for k in 1..<anchors.count { a = anchors[k - 1]; b = anchors[k]; if q <= b.quarter { break } }
            let time = a.time + (q - a.quarter) * (b.time - a.time) / (b.quarter - a.quarter)
            guard time >= 0, time <= duration else { throw MusicalError("The passage boundaries fall outside the detected performance. Choose boundaries closer to the played notes and record through the end boundary.") }
            beats.append(BeatTime(quarter: q, time: Double(fixed(time))!)); q += 1
        }
        try validate(beats, duration: duration)
        let origins: [BeatOrigin] = beats.map { beat in
            if matched.contains(where: { abs($0.0.startQuarter - beat.quarter) < 1e-7 }) { return .attack }
            if abs(last.0.endQuarter - beat.quarter) < 1e-7 { return .release }
            return .inferred
        }
        return AnalysisResult(beats: beats, matched: matched.count, total: notes.count, warning: "Draft estimate: review every beat. Repeated pitches, articulation, held notes and rests can make the alignment ambiguous. Beats between matched notes are interpolated; the final release is only an estimated end boundary.", origins: origins)
    }

    public static func validate(_ beats: [BeatTime], duration: Double) throws {
        guard beats.count >= 2 else { throw MusicalError("At least two beat boundaries are required.") }
        for i in beats.indices {
            guard beats[i].time.isFinite, beats[i].time >= 0, beats[i].time <= duration else { throw MusicalError("Every beat time must be inside the recording.") }
            if i > 0 && beats[i].time <= beats[i - 1].time { throw MusicalError("Beat times must increase strictly.") }
        }
    }

    public static func manual(range: PassageRange, start: Double, end: Double, duration: Double) throws -> [BeatTime] {
        let length = range.end - range.start
        guard length.isFinite, length >= 1, length <= 128, length.rounded() == length else { throw MusicalError("Choose a short passage of at most 32 measures for this first version.") }
        let beats = (0...Int(length)).map { BeatTime(quarter: range.start + Double($0), time: start + (end - start) * Double($0) / length) }
        try validate(beats, duration: duration)
        return beats
    }

    public static func simplify(_ beats: [BeatTime], duration: Double) throws -> [BeatTime] {
        try validate(beats, duration: duration)
        var proposed = beats, first = 0
        while first < proposed.count - 1 {
            var last = first + 1
            while last < proposed.count - 1 && proposed[last].quarter.truncatingRemainder(dividingBy: 4) != 0 { last += 1 }
            let start = proposed[first].time, end = proposed[last].time
            for i in (first + 1)..<last { proposed[i].time = start + (end - start) * Double(i - first) / Double(last - first) }
            first = last
        }
        return proposed
    }

    // JavaScript toFixed(3) rounds the exact binary value, with ties upward.
    // Scaling as a Double first would incorrectly round values such as 1.0005.
    private static func fixed(_ value: Double) -> String {
        let magnitude = abs(value)
        guard magnitude.isFinite, magnitude < 1e15 else {
            return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        let bits = magnitude.bitPattern
        let rawExponent = Int((bits >> 52) & 0x7ff)
        let significand = (bits & 0x000f_ffff_ffff_ffff) | (rawExponent == 0 ? 0 : 1 << 52)
        let product = significand * 125
        let exponent = (rawExponent == 0 ? -1022 : rawExponent - 1023) - 52 + 3
        let rounded: UInt64
        if exponent >= 0 { rounded = product << exponent }
        else if exponent <= -64 { rounded = 0 }
        else {
            let shift = -exponent
            let integral = product >> shift
            let remainder = product & ((UInt64(1) << shift) - 1)
            rounded = integral + (remainder >= UInt64(1) << (shift - 1) ? 1 : 0)
        }
        let fraction = String(rounded % 1000)
        return (value < 0 ? "-" : "") + String(rounded / 1000) + "." + String(repeating: "0", count: 3 - fraction.count) + fraction
    }

    public static func csv(beats: [BeatTime], range: PassageRange, midi: MIDIFile, duration: Double) throws -> String {
        try validate(beats, duration: duration)
        var lines = ["measure,beat,quarter_note_bpm,recording_seconds,action"], previous: String?
        for i in 0..<(beats.count - 1) {
            let b = beats[i], tempo = fixed(60 / (beats[i + 1].time - b.time))
            if tempo != previous { lines.append("\(Int(floor(b.quarter / 4)) + 1),\(Int(b.quarter.truncatingRemainder(dividingBy: 4)) + 1),\(tempo),\(fixed(b.time)),set") }
            previous = tempo
        }
        if range.end < midi.endQuarter {
            lines.append("\(Int(floor(range.end / 4)) + 1),\(Int(range.end.truncatingRemainder(dividingBy: 4)) + 1),\(fixed(midi.tempo(atSeconds: midi.seconds(atQuarter: range.end)))),\(fixed(beats.last!.time)),restore_original_tempo")
        }
        return lines.joined(separator: "\r\n")
    }

    public static func encodeWAV(samples: [Float], sampleRate: Double) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func word(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func integer(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        let count = UInt32(truncatingIfNeeded: samples.count * 2)
        let rate = sampleRate.isFinite && sampleRate > 0 && sampleRate < Double(UInt32.max) ? UInt32(sampleRate) : 0
        text("RIFF"); integer(36 &+ count); text("WAVE"); text("fmt "); integer(16)
        word(1); word(1); integer(rate); integer(rate &* 2); word(2); word(16); text("data"); integer(count)
        for sample in samples {
            let value = sample.isNaN ? 0 : max(-1, min(1, Double(sample)))
            word(UInt16(bitPattern: Int16(value * (value < 0 ? 32768 : 32767))))
        }
        return data
    }
}
