import XCTest
import ConductorCore
@testable import VirtualConductor

@MainActor final class GraceFollowingTests: XCTestCase {
    // An ornament followed by a principal that repeats half a beat later.
    private func plan(wait: Bool = false) throws -> FollowingPlan {
        let score = try MusicXMLScore(data: Data("""
        <score-partwise><part id="S"><measure number="1">
        <attributes><divisions>4</divisions><time><beats>4</beats><beat-type>4</beat-type></time>
        <transpose><chromatic>-2</chromatic></transpose></attributes>
        <note><rest/><duration>12</duration></note>
        <note><grace/><pitch><step>E</step><octave>4</octave></pitch></note>
        <note><grace/><pitch><step>D</step><octave>4</octave></pitch></note>
        <note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration></note>
        <note><pitch><step>B</step><octave>3</octave></pitch><duration>1</duration></note>
        <note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration></note>
        <note><pitch><step>A</step><octave>3</octave></pitch><duration>1</duration></note>
        </measure></part></score-partwise>
        """.utf8))
        return try FollowingPlan(score: score, solo: FollowingFixture.solo,
                                 waits: wait ? [WaitPoint(measure: 1, beat: 4)] : [], cadenzas: [])
    }

    func testOptionalAndLengthenedGracesResolveToPrincipalAndReplay() throws {
        let notes = try plan().notes, midi = try FollowingFixture.midi()
        XCTAssertEqual(notes.count, 4)
        XCTAssertEqual(notes[0].gracePitches, [62, 60])
        XCTAssertNil(notes[2].gracePitches)
        for length in [0, 4, 15, 25] {
            var tracker = SoloTracker()
            var report = FollowingDiagnostic(sampleRate: 8000, tolerance: 30, notes: notes, midi: midi)
            var time = 1.5
            func play(_ pitch: Int, frames: Int) -> [Int] {
                var matches: [Int] = []
                for _ in 0..<frames {
                    let before = tracker, q = midi.quarter(atSeconds: time)
                    let index = tracker.observe(pitch: pitch, time: time, notes: notes, expectedQuarter: q, free: false, midi: midi)
                    report.decisions.append(FollowingDecision(tracker: before, pitch: pitch, time: time, expectedQuarter: q,
                        free: false, throughQuarter: .infinity, rearticulated: false, matched: index, rate: tracker.rate, phase: "audio", level: 0.1))
                    if let index { matches.append(index) }
                    time += 0.01
                }
                return matches
            }
            XCTAssertTrue(play(62, frames: length / 2).isEmpty)
            XCTAssertTrue(play(60, frames: length - length / 2).isEmpty)
            XCTAssertNil(tracker.index)
            XCTAssertEqual(play(58, frames: 12), [0])
            XCTAssertEqual(tracker.rate, 1)
            XCTAssertEqual(play(57, frames: 13), [1])
            XCTAssertEqual(play(58, frames: 12), [2])
            XCTAssertEqual(play(55, frames: 12), [3])
            XCTAssertTrue(try FollowingDiagnostic.decode(report.encoded()).replay().isEmpty)
        }
    }

    func testFollowingDownbeatKeepsTheFirstOfTwoRepeatedNotes() throws {
        let midi = try FollowingFixture.midi()
        let notes = [60, 59, 57, 60, 65, 65].enumerated().map { index, pitch in
            let start = index == 5 ? 1.5 : Double(index) / 4
            return MIDINote(pitch: pitch, startQuarter: start, endQuarter: start + (index == 4 ? 0.5 : 0.25),
                            gracePitches: index == 0 ? [62] : nil)
        }
        var tracker = SoloTracker()
        func attack(_ pitch: Int, at time: Double) -> Int? {
            _ = tracker.observe(pitch: pitch, time: time, notes: notes, expectedQuarter: 2 * time, free: false, midi: midi)
            return tracker.observe(pitch: pitch, time: time + 0.01, notes: notes, expectedQuarter: 2 * time, free: false, midi: midi)
        }
        XCTAssertNil(attack(62, at: 0))
        for index in 0...4 {
            XCTAssertEqual(attack(notes[index].pitch, at: notes[index].startQuarter * 0.5 + 0.18), index)
        }
    }

    func testOmittedResolutionExpiresAndCannotPullTrackerBack() throws {
        let notes = try plan().notes, midi = try FollowingFixture.midi()
        var tracker = SoloTracker()
        for t in [1.49, 1.5] {
            _ = tracker.observe(pitch: 60, time: t, notes: notes, expectedQuarter: 3, free: false, midi: midi)
        }
        XCTAssertTrue(tracker.isPlayingGrace(at: 1.5))
        for t in [1.6, 1.7] {
            _ = tracker.observe(pitch: nil, time: t, notes: notes, expectedQuarter: 3.2, free: false, midi: midi)
        }
        XCTAssertFalse(tracker.isPlayingGrace(at: 2.5))
        _ = tracker.observe(pitch: 58, time: 2.5, notes: notes, expectedQuarter: 3.5, free: false, midi: midi)
        XCTAssertEqual(tracker.observe(pitch: 58, time: 2.51, notes: notes, expectedQuarter: 3.5, free: false, midi: midi), 2)
    }

    func testGraceAtExplicitWaitOnlyReleasesOnPrincipal() async throws {
        let prepared = try FollowingFixture.prepared(), audio = FollowingTestAudio()
        let diagnostics = FollowingDiagnostics(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var now = 0.0
        let following = LiveFollowing(diagnostics: diagnostics, capture: FollowingTestInput(), clock: { now }, permission: { true })
        try await following.start(prepared: prepared, plan: plan(wait: true), audio: audio, position: 0)
        defer { following.stop() }
        now = prepared.timing.prepSeconds + 1.5
        audio.sourcePosition = now
        following.tick()
        XCTAssertEqual(following.status, .waiting)
        let plays = audio.played.count
        for _ in 0..<85 {
            now += 0.01
            following.observe(pitch: 60, time: now)
            following.tick()
        }
        XCTAssertEqual(following.status, .waiting)
        XCTAssertEqual(audio.played.count, plays)
        for _ in 0..<2 {
            now += 0.01
            following.observe(pitch: 58, time: now)
        }
        XCTAssertEqual(audio.played.count, plays + 1)
        XCTAssertTrue(try XCTUnwrap(diagnostics.snapshot()).0.replay().isEmpty)
    }
}
