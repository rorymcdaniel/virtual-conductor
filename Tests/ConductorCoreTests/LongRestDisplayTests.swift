import XCTest
import ConductorCore
@testable import VirtualConductor

final class LongRestDisplayTests: XCTestCase {
    private func schedule(entrance: Double = 34.5) throws -> LongRestSchedule {
        let url = Bundle.module.url(forResource: "long-rest-eight-measures", withExtension: "musicxml", subdirectory: "Fixtures")!
        var xml = try String(contentsOf: url, encoding: .utf8)
        if entrance == 34 { xml = xml.replacingOccurrences(of: "<duration>5</duration>", with: "<duration>4</duration>").replacingOccurrences(of: "<duration>3</duration>", with: "<duration>4</duration>") }
        let score = try MusicXMLScore(data: Data(xml.utf8))
        return try LongRestSchedule(score: score, staffID: score.staves[0].id, threshold: 8)
    }
    private func timing(preparation: Int = 2, changingTempo: Bool = false, endQuarter: Int = 36) throws -> PerformanceTiming {
        func vlq(_ input: Int) -> [UInt8] {
            var value = input, result = [UInt8(value & 127)]; value >>= 7
            while value > 0 { result.insert(UInt8(value & 127) | 128, at: 0); value >>= 7 }
            return result
        }
        var track: [UInt8] = [0,255,81,3,7,161,32]
        if changingTempo { track += vlq(16 * 480) + [255,81,3,15,66,64] }
        track += vlq((endQuarter - (changingTempo ? 16 : 0)) * 480) + [255,47,0]
        let length = UInt32(track.count)
        let data = Data(Array("MThd".utf8) + [0,0,0,6,0,0,0,1,1,224] + Array("MTrk".utf8) + [UInt8(length >> 24),UInt8(length >> 16),UInt8(length >> 8),UInt8(length)] + track)
        return try PerformanceTiming(midi: MIDIFile(data: data), preparatoryMeasures: preparation)
    }
    private func display(_ quarter: Double, state: PerformanceState = .running, entrance: Double = 34.5, changingTempo: Bool = false) throws -> LongRestDisplay {
        let timing = try timing(changingTempo: changingTempo)
        let snapshot = ConductorSnapshot(time: timing.prepSeconds + timing.midi.seconds(atQuarter: quarter), segmentStart: 0, timing: timing, state: state)
        return LongRestDisplay(snapshot: snapshot, schedule: try schedule(entrance: entrance))
    }
    func testFullRestCounterAndPartialNinthMeasure() throws {
        for measure in 0..<8 {
            XCTAssertEqual(try display(Double(measure * 4)).counter, "\(measure + 1)/8")
            XCTAssertNil(try display(Double(measure * 4)).cueBeat)
        }
        XCTAssertEqual(try display(31.999).counter, "8/8")
        XCTAssertEqual(try display(32).counter, "8/8")
        XCTAssertEqual(try display(34.499).counter, "8/8")
        XCTAssertNil(try display(34.5).counter)
        XCTAssertNil(try display(34.501).counter)
    }
    func testCueBeginsAtContainingBeatForOnbeatAndOffbeatEntrances() throws {
        for entrance in [34.0, 34.5] {
            XCTAssertNil(try display(33.999, entrance: entrance).cueBeat)
            XCTAssertEqual(try display(34, entrance: entrance).cueBeat, 3)
            XCTAssertEqual(try display(34.5, entrance: entrance).cueBeat, 3)
            XCTAssertEqual(try display(34.999, entrance: entrance).cueBeat, 3)
            XCTAssertNil(try display(35, entrance: entrance).cueBeat)
            XCTAssertNil(try display(35.001, entrance: entrance).cueBeat)
        }
        XCTAssertNil(try display(34, entrance: 34).counter)
    }
    func testPreparationAndEndedAudioDoNotCountAsRests() throws {
        let timing = try timing(), schedule = try schedule()
        for time in [0.0, timing.leadSeconds, timing.prepSeconds - 0.001, timing.musicalEnd, timing.musicalEnd + 2] {
            let value = LongRestDisplay(snapshot: ConductorSnapshot(time: time, segmentStart: 0, timing: timing, state: .running), schedule: schedule)
            XCTAssertNil(value.counter); XCTAssertNil(value.cueBeat)
        }
        XCTAssertEqual(try display(0).counter, "1/8")
    }
    func testTempoChangesPreserveMusicalBoundaries() throws {
        for quarter in [0.0, 4, 16, 28, 32, 33.999, 34, 34.499, 34.5, 35] {
            XCTAssertEqual(try display(quarter), try display(quarter, changingTempo: true))
        }
    }
    func testTransportTransitionsDoNotRetainCue() throws {
        for state in [PerformanceState.empty, .loading, .ready, .starting, .waiting, .finished, .error] {
            let value = try display(34, state: state)
            XCTAssertNil(value.counter); XCTAssertNil(value.cueBeat)
        }
        for state in [PerformanceState.paused, .interrupted] {
            XCTAssertEqual(try display(34, state: state).counter, "8/8")
            XCTAssertNil(try display(34, state: state).cueBeat)
        }
        XCTAssertEqual(try display(34).cueBeat, 3)
        XCTAssertEqual(try display(0).counter, "1/8")
        XCTAssertNil(try display(0).cueBeat)
        let timing = try timing()
        XCTAssertNil(LongRestDisplay(snapshot: ConductorSnapshot(time: 34, segmentStart: 0, timing: timing, state: .running), schedule: nil).cueBeat)
    }
    func testTrailingRestNeverInventsCue() throws {
        let url = Bundle.module.url(forResource: "long-rest-separated-runs", withExtension: "musicxml", subdirectory: "Fixtures")!
        let score = try MusicXMLScore(data: Data(contentsOf: url))
        let schedule = try LongRestSchedule(score: score, staffID: score.staves[0].id, threshold: 1)
        let trailing = try XCTUnwrap(schedule.runs.last)
        XCTAssertNil(trailing.cue)
        let timing = try timing(endQuarter: 40)
        let snapshot = ConductorSnapshot(time: timing.prepSeconds + timing.midi.seconds(atQuarter: trailing.startQuarter), segmentStart: 0, timing: timing, state: .running)
        let value = LongRestDisplay(snapshot: snapshot, schedule: schedule)
        XCTAssertNotNil(value.counter); XCTAssertNil(value.cueBeat)
    }
}
