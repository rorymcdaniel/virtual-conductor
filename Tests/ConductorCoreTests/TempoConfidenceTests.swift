import XCTest
import ConductorCore

final class TempoConfidenceTests: XCTestCase {
    private let pitches = [60,62,64,65,60,62,64,65,60,62,64,65]
    private var notes: [MIDINote] {
        pitches.enumerated().map { MIDINote(pitch: $1, startQuarter: Double($0), endQuarter: Double($0+1)) }
    }

    func testWrongForwardMatchDoesNotBecomeTempoEvidence() throws {
        let midi = try FollowingFixture.midi()
        var tracker = SoloTracker()
        func attack(_ pitch: Int, quarter: Double, time: Double) {
            for offset in [0.0, 0.02] {
                tracker.observe(pitch: pitch, time: time+offset, notes: notes,
                                expectedQuarter: quarter, free: false, midi: midi)
            }
        }
        for q in 0...4 { attack(pitches[q], quarter: Double(q), time: Double(q)*0.5/0.87) }
        let trusted = tracker.rate
        XCTAssertEqual(trusted, 0.87, accuracy: 0.02)
        // A spurious F resembles a note three beats ahead. It is not faster playing.
        attack(65, quarter: 4.25, time: 4.25*0.5/0.87)
        XCTAssertEqual(tracker.rate, trusted, accuracy: 0.001)
        // The next actual note must remain reachable after that false lead.
        attack(62, quarter: 5, time: 5*0.5/0.87)
        XCTAssertEqual(tracker.index, 5)
        XCTAssertEqual(tracker.rate, trusted, accuracy: 0.001)
    }
    func testGenuineTempoChangesAreLearnedFromAConsistentPhrase() throws {
        let midi = try FollowingFixture.midi()
        for newPace in [0.82, 1.18] {
            var tracker = SoloTracker(), time = 0.0
            for q in pitches.indices {
                if q > 0 { time += 0.5 / (q < 4 ? 0.95 : newPace) }
                for offset in [0.0, 0.02] {
                    tracker.observe(pitch: pitches[q], time: time+offset, notes: notes,
                                    expectedQuarter: Double(q), free: false, midi: midi)
                }
                if q >= 7 {
                    XCTAssertTrue(tracker.hasReliableTempo)
                    XCTAssertEqual(tracker.rate, newPace, accuracy: 0.03)
                }
            }
        }
    }

    func testSkippedNotesRequireFreshConfirmationWithoutLosingTheEstablishedPace() throws {
        let midi = try FollowingFixture.midi()
        var tracker = SoloTracker()
        for q in [0,1,2,3,4,6,7,8] {
            for offset in [0.0, 0.02] {
                tracker.observe(pitch: pitches[q], time: Double(q)*0.5/0.87+offset, notes: notes,
                                expectedQuarter: Double(q), free: false, midi: midi)
            }
            if q >= 4 { XCTAssertEqual(tracker.rate, 0.87, accuracy: 0.02) }
            if q == 6 || q == 7 { XCTAssertFalse(tracker.hasReliableTempo) }
        }
        XCTAssertEqual(tracker.index, 8)
        XCTAssertTrue(tracker.hasReliableTempo)
    }

    func testLongNotesCanEstablishTempo() throws {
        let midi = try FollowingFixture.midi()
        let longNotes = [60,62,64,65].enumerated().map { MIDINote(pitch: $1, startQuarter: Double($0)*4, endQuarter: Double($0+1)*4) }
        var tracker = SoloTracker()
        for note in longNotes {
            for offset in [0.0, 0.02] {
                tracker.observe(pitch: note.pitch, time: note.startQuarter*0.5/0.9+offset, notes: longNotes,
                                expectedQuarter: note.startQuarter, free: false, midi: midi)
            }
        }
        XCTAssertTrue(tracker.hasReliableTempo)
        XCTAssertEqual(tracker.rate, 0.9, accuracy: 0.02)
    }

    func testRecoveryCanMoveBehindAnUnconfirmedMatch() throws {
        let midi = try FollowingFixture.midi()
        var tracker = SoloTracker()
        for q in 0...4 {
            for offset in [0.0, 0.02] {
                tracker.observe(pitch: pitches[q], time: Double(q)*0.5/0.87+offset, notes: notes,
                                expectedQuarter: Double(q), free: false, midi: midi)
            }
        }
        // A nearby but early next note is not yet a trustworthy tempo change.
        for offset in [0.0, 0.02] {
            tracker.observe(pitch: 62, time: 4.4*0.5/0.87+offset, notes: notes, expectedQuarter: 4.4, free: false, midi: midi)
        }
        XCTAssertFalse(tracker.hasReliableTempo)
        for offset in [0.0, 0.02] {
            tracker.observe(pitch: 60, time: 4.7*0.5/0.87+offset, notes: notes, expectedQuarter: 4.7, free: false, midi: midi)
        }
        XCTAssertEqual(tracker.index, 4)
        XCTAssertEqual(tracker.rate, 0.87, accuracy: 0.02)
    }

    func testUncertainAndStaleEvidenceHoldPlaybackButStillRespectTolerance() {
        var tempo = FollowingTempo()
        for _ in 0..<150 { _ = tempo.update(delta: 0.02, tolerance: 0.2, trackedRate: 0.87, phaseError: 0, age: 0) }
        let trusted = tempo.rate
        for _ in 0..<500 {
            XCTAssertEqual(tempo.update(delta: 0.02, tolerance: 0.2, trackedRate: 4, phaseError: 5, age: 0, reliable: false), trusted)
            XCTAssertEqual(tempo.update(delta: 0.02, tolerance: 0.2, trackedRate: 4, phaseError: 5, age: 100), trusted)
        }
        XCTAssertEqual(tempo.update(delta: 0.02, tolerance: 0.05, trackedRate: 4, phaseError: 5, age: 0, reliable: false), 0.95)
        for _ in 0..<100 { _ = tempo.update(delta: 0.02, tolerance: 0.2, trackedRate: 1.1, phaseError: 0, age: 0) }
        XCTAssertEqual(tempo.rate, 1.1, accuracy: 0.001)
    }

    func testShortRecoveryBurstCannotSetANewTempo() throws {
        let midi = try FollowingFixture.midi()
        let beats = [0.0, 1, 2, 3, 4, 4.333333, 4.666667, 5, 5.333333]
        let reference = beats.enumerated().map { MIDINote(pitch: 60+$0, startQuarter: $1, endQuarter: $1+0.3) }
        var tracker = SoloTracker()
        for i in 0...2 {
            for offset in [0.0, 0.02] {
                tracker.observe(pitch: reference[i].pitch, time: Double(i)*0.5/0.87+offset, notes: reference,
                                expectedQuarter: beats[i], free: false, midi: midi)
            }
        }
        let trusted = tracker.rate
        // Reacquire after a missed note, then hear just two short intervals.
        for (i,time) in [(4,2.3),(5,2.45),(6,2.77)] {
            for offset in [0.0, 0.02] {
                tracker.observe(pitch: reference[i].pitch, time: time+offset, notes: reference,
                                expectedQuarter: beats[i], free: false, midi: midi)
            }
        }
        XCTAssertFalse(tracker.hasReliableTempo)
        XCTAssertEqual(tracker.rate, trusted)
    }

    func testUnevenRecoveryCannotUseItsAverageAsTempo() throws {
        let midi = try FollowingFixture.midi()
        let beats = [0.0, 1, 2, 3, 4, 4+1.0/3, 4+2.0/3, 5, 5+1.0/3]
        let reference = beats.enumerated().map { MIDINote(pitch: 60+$0, startQuarter: $1, endQuarter: $1+0.3) }
        var tracker = SoloTracker()
        for i in 0...2 {
            for offset in [0.0, 0.02] {
                tracker.observe(pitch: reference[i].pitch, time: Double(i)*0.5/0.87+offset, notes: reference,
                                expectedQuarter: beats[i], free: false, midi: midi)
            }
        }
        let trusted = tracker.rate
        // The average fits a faster pace, but the intervals contradict each other.
        for (i,time) in [(4,2.3),(5,2.4),(6,2.66),(7,2.77),(8,2.97)] {
            for offset in [0.0, 0.02] {
                tracker.observe(pitch: reference[i].pitch, time: time+offset, notes: reference,
                                expectedQuarter: beats[i], free: false, midi: midi)
            }
        }
        XCTAssertFalse(tracker.hasReliableTempo)
        XCTAssertEqual(tracker.rate, trusted)
    }

}
