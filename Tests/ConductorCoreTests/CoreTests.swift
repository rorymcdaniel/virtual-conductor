import XCTest
@testable import ConductorCore

final class CoreTests: XCTestCase {
    private func fixture(_ name: String, extension ext: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    private func reference() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("reference", extension: "json")) as? [String: Any])
    }
    private func score() throws -> MIDIFile {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "synthetic-score", withExtension: "mid", subdirectory: "Fixtures"))
        return try MIDIFile(data: Data(contentsOf: url))
    }

    func testReferenceMIDIAndExactBeatPositions() throws {
        let midi = try score()
        let source = try XCTUnwrap(reference()["source"] as? [String: Any])
        XCTAssertEqual(midi.ppqn, source["ppqn"] as? Int)
        XCTAssertEqual(midi.tracks.count, source["trackCount"] as? Int)
        XCTAssertEqual(midi.endQuarter, source["endQuarter"] as! Double, accuracy: 1e-10)
        XCTAssertEqual(midi.duration, source["duration"] as! Double, accuracy: 1e-8)
        XCTAssertEqual(midi.measures, source["measures"] as? Int)
        for (track, expected) in zip(midi.tracks, source["trackNotes"] as! [[String: Any]]) {
            XCTAssertEqual(track.name, expected["name"] as? String)
            XCTAssertEqual(track.notes, expected["notes"] as? Int)
            XCTAssertTrue(track.noteEvents.allSatisfy { $0.endQuarter >= $0.startQuarter })
        }
        for (segment, expected) in zip(midi.segments, source["tempoSegments"] as! [[String: Double]]) {
            XCTAssertEqual(segment.quarter, expected["quarter"]!, accuracy: 1e-10)
            XCTAssertEqual(segment.seconds, expected["seconds"]!, accuracy: 1e-8)
            XCTAssertEqual(segment.secondsPerQuarter, expected["secondsPerQuarter"]!, accuracy: 1e-10)
        }
        for prep in [0, 1, 2, 5, 99] {
            let timing = try PerformanceTiming(midi: midi, preparatoryMeasures: prep)
            for q in 0..<Int(midi.endQuarter) {
                let p = timing.position(timing.beatTime(timing.prepBeats + q))
                XCTAssertEqual(p.beat, q % 4)
                XCTAssertEqual(p.measure, q / 4 + 1)
                XCTAssertEqual(p.f, 0, accuracy: 1e-8)
            }
            let end = timing.position(timing.musicalEnd + 20)
            XCTAssertTrue(end.ended)
            XCTAssertEqual(end.measure, midi.measures)
        }
    }

    func testBrowserPreparationAndGeometryFixtures() throws {
        let expected = try reference(), midi = try score()
        for (count, raw) in expected["preparation"] as! [String: [String: Any]] {
            let timing = try PerformanceTiming(midi: midi, preparatoryMeasures: Int(count)!)
            XCTAssertEqual(timing.prepBeats, raw["prepBeats"] as? Int)
            XCTAssertEqual(timing.totalBeats, raw["totalBeats"] as? Int)
            XCTAssertEqual(timing.prepSeconds, raw["prepSeconds"] as! Double, accuracy: 1e-8)
            for sample in raw["samples"] as! [[String: Any]] {
                let p = timing.position(sample["time"] as! Double)
                let e = sample["position"] as! [String: Any]
                XCTAssertEqual(p.beat, e["beat"] as? Int)
                XCTAssertEqual(p.measure, e["measure"] as? Int)
                XCTAssertEqual(p.preparing, e["preparing"] as? Bool)
                XCTAssertEqual(p.leadIn, e["leadIn"] as? Bool ?? false)
                XCTAssertEqual(p.ended, e["ended"] as? Bool)
                XCTAssertEqual(p.f, e["f"] as! Double, accuracy: 1e-8)
                XCTAssertEqual(p.bpm, e["bpm"] as! Double, accuracy: 1e-8)
            }
        }
        let geometry = expected["geometry"] as! [String: Any]
        for samples in geometry["samples"] as! [[[String: Any]]] {
            for sample in samples {
                let p = ConductorGeometry.point(beat: sample["beat"] as! Int, phase: sample["f"] as! Double)
                let e = sample["point"] as! [Double]
                XCTAssertEqual(p.x, e[0], accuracy: 1e-12)
                XCTAssertEqual(p.y, e[1], accuracy: 1e-12)
            }
        }
    }

    func testFractionalTempoMapAndRoundTrips() throws {
        let midi = try MIDIFile(data: fixture("fractional-tempo", extension: "mid"))
        let root = try JSONSerialization.jsonObject(with: fixture("fractional-tempo", extension: "json")) as! [String: Any]
        let parsed = root["parsed"] as! [String: Any]
        XCTAssertEqual(midi.duration, parsed["duration"] as! Double, accuracy: 1e-10)
        XCTAssertEqual(midi.tracks[0].noteEvents, [MIDINote(pitch: 60, startQuarter: 0, endQuarter: 2), MIDINote(pitch: 64, startQuarter: 4, endQuarter: 5)])
        for probe in parsed["probes"] as! [[String: Double]] {
            let seconds = midi.seconds(atQuarter: probe["quarter"]!)
            XCTAssertEqual(seconds, probe["seconds"]!, accuracy: 1e-10)
            XCTAssertEqual(midi.quarter(atSeconds: seconds), probe["roundTrip"]!, accuracy: 1e-10)
            XCTAssertEqual(midi.tempo(atSeconds: seconds), probe["bpm"]!, accuracy: 1e-10)
        }
    }

    func testCadenzaValidationAndAllChannelWarning() throws {
        let midi = try score()
        let a = CadenzaPassage(startMeasure: 1, startBeat: 2, returnMeasure: 11, returnBeat: 3)
        let b = CadenzaPassage(startMeasure: 12, startBeat: 2, returnMeasure: 14, returnBeat: 1)
        let compiled = try compileCadenzas([b, a], midi: midi, audioDuration: 437)
        XCTAssertEqual(compiled.map(\.passage), [a, b])
        let golden = try XCTUnwrap(reference()["cadenza"] as? [String: Any])["compiled"] as! [[String: Any]]
        XCTAssertEqual(compiled[0].returnSeconds, golden[0]["returnSeconds"] as! Double, accuracy: 1e-8)
        XCTAssertThrowsError(try compileCadenzas([a, a], midi: midi, audioDuration: 437))
        XCTAssertThrowsError(try compileCadenzas([a], midi: midi, audioDuration: 10))
        for bad in [CadenzaPassage(startMeasure: 0, startBeat: 1, returnMeasure: 2, returnBeat: 1), CadenzaPassage(startMeasure: 1, startBeat: 5, returnMeasure: 2, returnBeat: 1), CadenzaPassage(startMeasure: 3, startBeat: 1, returnMeasure: 2, returnBeat: 1), CadenzaPassage(startMeasure: 1, startBeat: 1, returnMeasure: Int.max, returnBeat: 1)] {
            XCTAssertThrowsError(try compileCadenzas([bad], midi: midi, audioDuration: 437))
        }
        let range = CompiledCadenza(passage: a, startQuarter: 0, returnQuarter: 1, startSeconds: 1, returnSeconds: 2)
        let silent = [Float](repeating: 0.00001, count: 3000)
        var right = silent
        right[2000] = 1
        XCTAssertEqual(accompanimentInCadenzas([range], channels: [silent, right], sampleRate: 1000), [])
        right[1999] = 0.1
        XCTAssertEqual(accompanimentInCadenzas([range], channels: [silent, right], sampleRate: 1000), [range])
    }

    func testTruncatedAndMalformedMIDIAreErrors() throws {
        let valid = try fixture("fractional-tempo", extension: "mid")
        for count in 0..<valid.count { XCTAssertThrowsError(try MIDIFile(data: valid.prefix(count))) }
        var smpte = valid; smpte[12] = 0x80
        XCTAssertThrowsError(try MIDIFile(data: smpte))
        var format = valid; format[9] = 2
        XCTAssertThrowsError(try MIDIFile(data: format))
        let midi = try MIDIFile(data: valid)
        XCTAssertThrowsError(try PerformanceTiming(midi: midi, preparatoryMeasures: -1))
        XCTAssertThrowsError(try PerformanceTiming(midi: midi, preparatoryMeasures: 100))
    }

    func testRunningStatusRepeatedNotesAndMeterRejection() throws {
        func file(_ events: [UInt8]) -> Data {
            let length = UInt32(events.count)
            return Data([0x4d, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 1, 0xe0,
                         0x4d, 0x54, 0x72, 0x6b, UInt8(length >> 24), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)] + events)
        }
        // Reattacking an active pitch closes the first note; velocity zero
        // closes the reattack under running status, while EOT closes pitch 62.
        let events: [UInt8] = [0, 0x90, 60, 90, 0x83, 0x60, 60, 80, 0, 62, 80,
                               0x83, 0x60, 60, 0, 0x83, 0x60, 0xff, 0x2f, 0]
        let midi = try MIDIFile(data: file(events))
        XCTAssertEqual(midi.tracks[0].noteEvents, [MIDINote(pitch: 60, startQuarter: 0, endQuarter: 1), MIDINote(pitch: 60, startQuarter: 1, endQuarter: 2), MIDINote(pitch: 62, startQuarter: 1, endQuarter: 3)])
        for malformed: [UInt8] in [[0, 60, 80], [0, 0xff, 0x51, 3, 0, 0, 0], [0, 0x90, 128, 90], [0x80, 0x80, 0x80, 0x80], [0, 0xff, 0x58, 2, 3, 2] + events] {
            XCTAssertThrowsError(try MIDIFile(data: file(malformed)))
        }
    }
}
