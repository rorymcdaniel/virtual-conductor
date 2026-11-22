import XCTest
import ConductorCore

final class NaturalFollowingTests: XCTestCase {
    func testConsecutiveOffsetsCanSteerAnUnevenPhraseWithoutChangingItsEstablishedPulse() throws {
        let midi = try FollowingFixture.midi()
        let notes = (0..<6).map { i in
            MIDINote(pitch: 60 + i, startQuarter: Double(2 * i + 2), endQuarter: Double(2 * i + 4))
        }
        for offset in [-0.32, 0.32] {
            var tracker = SoloTracker(), tempo = FollowingTempo()
            let onsets = [0.0, 0.7, 2.1, 2.8, 4.2]
            for (i, onset) in onsets.enumerated() {
                for frame in 0..<50 {
                    let time = onset + Double(frame) / 100
                    let scoreTime = midi.seconds(atQuarter: notes[i].startQuarter) + offset + time - onset
                    tracker.observe(pitch: notes[i].pitch, time: time, notes: notes,
                        expectedQuarter: midi.quarter(atSeconds: scoreTime), free: false, midi: midi,
                        accompanimentAtOnset: { scoreTime + $0 - time })
                    let input = FollowingTempoInput.accompanied(delta: 0.01, tolerance: 0.3, tracker: tracker,
                        notes: notes, midi: midi, scoreTime: scoreTime, time: time)
                    _ = tempo.update(input)
                    XCTAssertFalse(tracker.hasReliableTempo)
                    if i < 2 { XCTAssertEqual(tempo.rate, 1) }
                    XCTAssertTrue((0.96...1.04).contains(tempo.rate))
                }
            }
            XCTAssertGreaterThan((1 - tempo.rate) * (offset > 0 ? 1 : -1), 0.02)
            for time in [4.70, 4.71] {
                tracker.observe(pitch: 90, time: time, notes: notes, expectedQuarter: 11, free: false, midi: midi)
            }
            let unmatched = FollowingTempoInput.accompanied(delta: 0.01, tolerance: 0.3, tracker: tracker,
                notes: notes, midi: midi, scoreTime: midi.seconds(atQuarter: 11), time: 4.71)
            XCTAssertTrue(unmatched.isHolding)
            for _ in 0..<200 { _ = tempo.update(unmatched) }
            XCTAssertEqual(tempo.rate, 1, accuracy: 0.001)
        }
    }

    func testPositionRecoveryCannotTurnSteadyPlayingIntoALargeTempoChange() {
        for error in [-0.5, 0.5] {
            var tempo = FollowingTempo()
            for _ in 0..<200 {
                let rate = tempo.update(delta: 0.01, tolerance: 0.2, trackedRate: 1,
                                        phaseError: error, age: 0)
                XCTAssertTrue((0.96...1.04).contains(rate), "Position recovery has its own small allowance")
            }
        }
    }
}
