import XCTest
import ConductorCore
@testable import VirtualConductor

@MainActor final class FollowingDiagnosticsTests: XCTestCase {
    func testBoundedOptionalAudioAndReplayAfterSaving() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = FollowingDiagnostics(root: root)
        let midi = try FollowingFixture.midi(), plan = try FollowingPlan(score: FollowingFixture.score(), solo: FollowingFixture.solo, waits: [], cadenzas: [])
        diagnostics.begin(sampleRate: 8000, tolerance: 10, plan: plan, midi: midi)
        diagnostics.capture([Float](repeating: 0.2, count: 8000), start: 0)
        XCTAssertTrue(try XCTUnwrap(diagnostics.snapshot()).1.isEmpty)
        diagnostics.includeAudio = true
        for second in 0..<20 { diagnostics.capture([Float](repeating: 0.2, count: 8000), start: Double(second)) }
        let snapshot = try XCTUnwrap(diagnostics.snapshot())
        XCTAssertEqual(snapshot.1.count, 120000); XCTAssertEqual(snapshot.0.audioStart, 5); XCTAssertEqual(snapshot.0.audioEnd, 20)
        var tracker = SoloTracker()
        for i in 0..<3100 {
            let time = Double(i) * 0.01, before = tracker
            let pitch = i < 40 ? 60 : 62
            let match = tracker.observe(pitch: pitch, time: time, notes: plan.notes, expectedQuarter: 0, free: true, midi: midi)
            diagnostics.record(FollowingDecision(tracker: before, pitch: pitch, time: time, expectedQuarter: 0, free: true, throughQuarter: .infinity,
                                                 rearticulated: false, matched: match, rate: tracker.rate, phase: "free", level: 0.2))
        }
        XCTAssertLessThanOrEqual(diagnostics.report!.decisions.count, 3000)
        diagnostics.notice("Synthetic interruption", time: 31)
        diagnostics.save()
        while diagnostics.saving { await Task.yield() }
        let url = try XCTUnwrap(diagnostics.savedURL)
        let report = try FollowingDiagnostic.decode(Data(contentsOf: url.appendingPathComponent("report.json")))
        XCTAssertTrue(report.replay().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("audio.wav").path))
        diagnostics.includeAudio = false
        XCTAssertTrue(try XCTUnwrap(diagnostics.snapshot()).1.isEmpty)
        diagnostics.save(); while diagnostics.saving { await Task.yield() }
        let silentURL = try XCTUnwrap(diagnostics.savedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: silentURL.appendingPathComponent("audio.wav").path))
        XCTAssertNil(try XCTUnwrap(diagnostics.snapshot()).0.audioStart)
    }
}
