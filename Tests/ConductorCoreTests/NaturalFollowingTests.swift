import XCTest
import ConductorCore

final class NaturalFollowingTests: XCTestCase {
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
