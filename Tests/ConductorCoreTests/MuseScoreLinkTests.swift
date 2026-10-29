import XCTest
import ConductorCore
@testable import VirtualConductor

@MainActor final class MuseScoreLinkTests: XCTestCase {
    private func midi() throws -> MIDIFile {
        try MIDIFile(data: Data(contentsOf: Bundle.module.url(forResource: "fractional-tempo", withExtension: "mid", subdirectory: "Fixtures")!))
    }
    func testTempoRequestUsesBeatDistanceAndRestoresOriginalTempo() throws {
        let score = try midi()
        let range = PassageRange(start: 0, end: 2)
        let beats = [BeatTime(quarter: 0, time: 0), BeatTime(quarter: 1, time: 1), BeatTime(quarter: 2, time: 1.5)]
        let points = try MuseScoreLink.points(beats: beats, range: range, midi: score, duration: 2)
        XCTAssertEqual(points[0], TempoPoint(quarter: 0, bpm: 60))
        XCTAssertEqual(points[1], TempoPoint(quarter: 1, bpm: 120))
        XCTAssertEqual(points.last?.quarter, 2)
        XCTAssertEqual(points.last!.bpm, score.tempo(atSeconds: score.seconds(atQuarter: 2)))
    }
    func testRejectsTimingForAnotherPassage() throws {
        XCTAssertThrowsError(try MuseScoreLink.points(beats: [BeatTime(quarter: 0,time: 0), BeatTime(quarter: 1,time: 1)], range: PassageRange(start: 1,end: 2), midi: midi(), duration: 2))
    }
    func testLinkedRefreshRetainsRecordingAndTiming() throws {
        let model = RecordingModel(audio: PerformanceAudio())
        let score = try midi()
        model.setScore(score, fingerprint: "before")
        model.take = RecordedTake(samples: [0.1,0.2], sampleRate: 2, range: PassageRange(start: 0,end: 1))
        model.beats = [BeatTime(quarter: 0,time: 0),BeatTime(quarter: 1,time: 1)]
        model.trackIndex = 0
        model.refreshLinkedScore(score, fingerprint: "after")
        XCTAssertEqual(model.take?.samples,[0.1,0.2]); XCTAssertEqual(model.beats.count,2); XCTAssertEqual(model.trackIndex,0)
    }
}
