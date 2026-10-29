import XCTest
@testable import ConductorCore

final class InterpretationTests: XCTestCase {
    private func midi() throws -> MIDIFile {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "synthetic-score", withExtension: "mid", subdirectory: "Fixtures"))
        return try MIDIFile(data: Data(contentsOf: url))
    }

    func testManualCSVMatchesBrowserReference() throws {
        let source = Bundle.module.url(forResource: "reference", withExtension: "json", subdirectory: "Fixtures")!
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as! [String: Any]
        let expected = (fixture["csv"] as! [String: Any])["text"] as! String
        let score = try midi()
        let range = try Interpretation.range(startMeasure: 1, startBeat: 1, endMeasure: 2, endBeat: 1, midi: score)
        let beats = try Interpretation.manual(range: range, start: 0.5, end: 2, duration: 3)
        XCTAssertEqual(try Interpretation.csv(beats: beats, range: range, midi: score, duration: 3), expected)
        XCTAssertEqual(beats.map(\.time), [0.5, 0.875, 1.25, 1.625, 2])
    }

    func testAlignmentInterpolatesAndAcceptsOctaveMatches() throws {
        let notes = (0..<4).map { MIDINote(pitch: 60 + $0, startQuarter: Double($0), endQuarter: Double($0 + 1)) }
        let observed = (0..<4).map { ObservedNote(pitch: 72 + $0, start: 0.5 + Double($0) * 0.6, end: 0.5 + Double($0 + 1) * 0.6) }
        let result = try Interpretation.align(observed: observed, reference: notes, range: PassageRange(start: 0, end: 4), duration: 3)
        XCTAssertEqual(result.matched, 4)
        XCTAssertEqual(result.beats.map(\.time), [0.5, 1.1, 1.7, 2.3, 2.9])
        XCTAssertTrue(result.warning.contains("interpolated"))
        XCTAssertThrowsError(try Interpretation.align(observed: observed.map { ObservedNote(pitch: 90, start: $0.start, end: $0.end) }, reference: notes, range: PassageRange(start: 0, end: 4), duration: 3))
    }

    func testSynthesizedSoloMatchesBrowserTimingExpectations() throws {
        let score = try midi(), reference = score.tracks[0].noteEvents
        let rate = 16000.0
        func seconds(_ q: Double) -> Double { 1.5 + q * 0.6 + q * q * 0.01 }
        var samples = [Float](repeating: 0, count: Int(ceil((seconds(8) + 0.3) * rate)))
        for note in reference where note.startQuarter < 8 {
            let start = seconds(note.startQuarter), end = seconds(min(8, note.endQuarter))
            let frequency = 440 * pow(2, Double(note.pitch - 69) / 12)
            for i in Int(ceil(start * rate))..<Int(floor(end * rate)) {
                let t = Double(i) / rate - start
                let envelope = min(1, t / 0.01, (end - Double(i) / rate) / 0.015)
                samples[i] = Float(0.3 * envelope * (sin(2 * .pi * frequency * t) + 0.2 * sin(4 * .pi * frequency * t)))
            }
        }
        let result = try Interpretation.analyze(samples: samples, sampleRate: rate, reference: reference, range: PassageRange(start: 0, end: 8))
        XCTAssertEqual(result.matched, 6)
        XCTAssertEqual(result.beats.count, 9)
        // Captured from tempo-analysis.mjs analyzeTake with this synthesized PCM.
        let expectedURL = try XCTUnwrap(Bundle.module.url(forResource: "synthetic-analysis", withExtension: "json", subdirectory: "Fixtures"))
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: expectedURL)) as! [String: Any]
        XCTAssertEqual(result.beats.map(\.time), (expected["beats"] as! [[String: Double]]).map { $0["time"]! })
        for beat in result.beats { XCTAssertEqual(beat.time, seconds(beat.quarter), accuracy: 0.08) }
        XCTAssertGreaterThan(60 / (result.beats[1].time - result.beats[0].time), 60 / (result.beats[8].time - result.beats[7].time))
    }

    func testRejectionsAndSimplification() throws {
        let score = try midi()
        XCTAssertThrowsError(try Interpretation.range(startMeasure: 1, startBeat: 5, endMeasure: 2, endBeat: 1, midi: score))
        XCTAssertThrowsError(try Interpretation.range(startMeasure: 1, startBeat: 1, endMeasure: 34, endBeat: 1, midi: score))
        XCTAssertThrowsError(try Interpretation.validate([BeatTime(quarter: 0, time: 1), BeatTime(quarter: 1, time: 1)], duration: 3))
        XCTAssertThrowsError(try Interpretation.validate([BeatTime(quarter: 0, time: 0), BeatTime(quarter: 1, time: .nan)], duration: 3))
        XCTAssertThrowsError(try Interpretation.analyze(samples: [Float](repeating: 0, count: 32000), sampleRate: 16000, reference: score.tracks[0].noteEvents, range: PassageRange(start: 0, end: 8)))
        let beats = zip(2...8, [0.0, 0.8, 1.0, 1.8, 2.3, 2.6, 3.0]).map { BeatTime(quarter: Double($0.0), time: $0.1) }
        let simplified = try Interpretation.simplify(beats, duration: 3)
        XCTAssertEqual(simplified.map(\.time), [0, 0.5, 1, 1.5, 2, 2.5, 3])
        let atEnd = try Interpretation.manual(range: PassageRange(start: 60, end: 64), start: 0, end: 2, duration: 2)
        XCTAssertFalse(try Interpretation.csv(beats: atEnd, range: PassageRange(start: 60, end: 64), midi: score, duration: 2).contains("restore"))
    }

    func testCSVUsesJavaScriptExactBinaryRounding() throws {
        let score = try midi()
        let beats = [BeatTime(quarter: 0, time: 0.0625), BeatTime(quarter: 1, time: 1.0005)]
        let csv = try Interpretation.csv(beats: beats, range: PassageRange(start: 0, end: 1), midi: score, duration: 2)
        // (0.0625).toFixed(3) === '0.063'; (1.0005).toFixed(3) === '1.000'.
        XCTAssertTrue(csv.contains(",0.063,set"))
        XCTAssertTrue(csv.contains(",1.000,restore_original_tempo"))
    }

    func testWAVMatchesPCM16Encoding() {
        let data = Interpretation.encodeWAV(samples: [-2, 0, 0.5, 2], sampleRate: 48000)
        func word(_ i: Int) -> UInt16 { UInt16(data[i]) | UInt16(data[i + 1]) << 8 }
        XCTAssertEqual(data.count, 52)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(word(22), 1)
        XCTAssertEqual(word(24), 48000)
        XCTAssertEqual(Int16(bitPattern: word(44)), -32768)
        XCTAssertEqual(Int16(bitPattern: word(48)), 16383)
        XCTAssertEqual(Int16(bitPattern: word(50)), 32767)
    }
}
