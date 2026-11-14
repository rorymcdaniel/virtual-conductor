import XCTest
import ConductorCore
@testable import VirtualConductor

@MainActor final class FollowingDiagnosticsTests: XCTestCase {
    func testOptingOutDuringAFailedSaveCannotRestoreAudioOnRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("blocked".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = FollowingDiagnostics(root: root)
        let plan = try FollowingPlan(score: FollowingFixture.score(), solo: FollowingFixture.solo, waits: [], cadenzas: [])
        diagnostics.begin(sampleRate: 8000, tolerance: 20, plan: plan, midi: try FollowingFixture.midi())
        diagnostics.includeAudio = true
        diagnostics.capture([Float](repeating: 0.1, count: 800), start: 0)
        diagnostics.preserveIncident("Test failure", time: 0)
        diagnostics.includeAudio = false
        while diagnostics.saving { await Task.yield() }
        try FileManager.default.removeItem(at: root)
        diagnostics.save()
        while diagnostics.saving { await Task.yield() }
        let url = try XCTUnwrap(diagnostics.savedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("audio.wav").path))
        XCTAssertNil(try FollowingDiagnostic.decode(Data(contentsOf: url.appendingPathComponent("report.json"))).audioStart)
    }

    func testAutomaticStorageIsBoundedAndManualReportsSurvive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = FollowingDiagnostics(root: root)
        let midi = try FollowingFixture.midi(), plan = try FollowingPlan(score: FollowingFixture.score(), solo: FollowingFixture.solo, waits: [], cadenzas: [])
        diagnostics.begin(sampleRate: 8000, tolerance: 20, plan: plan, midi: midi)
        diagnostics.notice("Manual keeper", time: 0); diagnostics.save()
        while diagnostics.saving { await Task.yield() }
        let manual = try XCTUnwrap(diagnostics.savedURL)
        for session in 0..<14 {
            diagnostics.begin(sampleRate: 8000, tolerance: 20, plan: plan, midi: midi)
            diagnostics.includeAudio = session == 13
            diagnostics.capture([Float](repeating: 0.1, count: 800), start: 0)
            XCTAssertTrue(diagnostics.preserveIncident("Test incident", time: 0))
            while diagnostics.saving { await Task.yield() }
        }
        let automatic = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Automatic"), includingPropertiesForKeys: nil)
        XCTAssertEqual(automatic.count, 12)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manual.appendingPathComponent("report.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(diagnostics.savedURL).appendingPathComponent("audio.wav").path))
        XCTAssertFalse(diagnostics.preserveIncident("Too soon", time: 10))
        XCTAssertTrue(diagnostics.preserveIncident("Next incident", time: 31))
        while diagnostics.saving { await Task.yield() }
        XCTAssertTrue(diagnostics.preserveIncident("Third incident", time: 62))
        while diagnostics.saving { await Task.yield() }
        XCTAssertFalse(diagnostics.preserveIncident("Session cap", time: 100))
    }

    func testFailedAutomaticSaveRetainsEvidenceForRetryAcrossANewPerformance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("blocked".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = FollowingDiagnostics(root: root)
        let midi = try FollowingFixture.midi(), plan = try FollowingPlan(score: FollowingFixture.score(), solo: FollowingFixture.solo, waits: [], cadenzas: [])
        diagnostics.begin(sampleRate: 8000, tolerance: 20, plan: plan, midi: midi)
        XCTAssertTrue(diagnostics.preserveIncident("Original incident", time: 1))
        while diagnostics.saving { await Task.yield() }
        XCTAssertTrue(diagnostics.message.contains("could not be saved"))
        diagnostics.begin(sampleRate: 8000, tolerance: 20, plan: plan, midi: midi)
        XCTAssertTrue(diagnostics.canSave)
        try FileManager.default.removeItem(at: root)
        diagnostics.save()
        while diagnostics.saving { await Task.yield() }
        let report = try FollowingDiagnostic.decode(Data(contentsOf: try XCTUnwrap(diagnostics.savedURL).appendingPathComponent("report.json")))
        XCTAssertTrue(report.notices.contains { $0.reason.contains("Original incident") })
    }

    func testTempoLimitRequiresDwellAndIntentionalWaitsAreNotIncidents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = FollowingDiagnostics(root: root)
        let plan = try FollowingPlan(score: FollowingFixture.score(), solo: FollowingFixture.solo, waits: [], cadenzas: [])
        diagnostics.begin(sampleRate: 8000, tolerance: 20, plan: plan, midi: try FollowingFixture.midi())
        for status in [FollowingStatus.waiting, .cadenza] {
            diagnostics.monitor(status: status, time: 0, atTempoLimit: true)
            diagnostics.monitor(status: status, time: 60, atTempoLimit: true)
        }
        XCTAssertNil(diagnostics.savedURL)
        diagnostics.monitor(status: .following, time: 61, atTempoLimit: true)
        diagnostics.monitor(status: .following, time: 62, atTempoLimit: true)
        XCTAssertFalse(diagnostics.saving)
        diagnostics.monitor(status: .following, time: 63.1, atTempoLimit: true)
        while diagnostics.saving { await Task.yield() }
        XCTAssertNotNil(diagnostics.savedURL)
    }

    func testAutomaticIncidentPreservesReportWithoutRepeatedSaves() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = FollowingDiagnostics(root: root)
        let midi = try FollowingFixture.midi(), plan = try FollowingPlan(score: FollowingFixture.score(), solo: FollowingFixture.solo, waits: [], cadenzas: [])
        diagnostics.begin(sampleRate: 8000, tolerance: 20, plan: plan, midi: midi)
        diagnostics.notice("Started", time: 0)
        diagnostics.monitor(status: .holding, time: 0)
        diagnostics.monitor(status: .holding, time: 2)
        XCTAssertNil(diagnostics.savedURL)
        diagnostics.monitor(status: .holding, time: 3.1)
        while diagnostics.saving { await Task.yield() }
        let first = try XCTUnwrap(diagnostics.savedURL)
        let report = try FollowingDiagnostic.decode(Data(contentsOf: first.appendingPathComponent("report.json")))
        XCTAssertTrue(report.notices.contains { $0.reason.contains("Holding tempo") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.appendingPathComponent("audio.wav").path))
        for time in [4.0, 15, 40, 90] { diagnostics.monitor(status: .holding, time: time) }
        while diagnostics.saving { await Task.yield() }
        XCTAssertEqual(diagnostics.savedURL, first, "One continuous incident produces one report")
        diagnostics.monitor(status: .following, time: 91)
        diagnostics.monitor(status: .lost, time: 92)
        while diagnostics.saving { await Task.yield() }
        XCTAssertNotEqual(diagnostics.savedURL, first)
    }

    func testBoundedOptionalAudioAndReplayAfterSaving() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = FollowingDiagnostics(root: root)
        let midi = try FollowingFixture.midi(), plan = try FollowingPlan(score: FollowingFixture.score(), solo: FollowingFixture.solo, waits: [], cadenzas: [])
        diagnostics.begin(sampleRate: 8000, tolerance: 10, plan: plan, midi: midi)
        diagnostics.capture([Float](repeating: 0.2, count: 8000), start: 0)
        XCTAssertTrue(try XCTUnwrap(diagnostics.snapshot()).1.isEmpty)
        diagnostics.includeAudio = true
        for second in 0..<20 {
            let tone = (0..<8000).map { Float(0.2 * sin(2 * .pi * 261.6256 * (Double(second) + Double($0) / 8000))) }
            diagnostics.capture(tone, start: Double(second))
        }
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
        if let destination = ProcessInfo.processInfo.environment["VC_DIAGNOSTIC_FIXTURE_OUTPUT"] {
            try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: destination))
        }
        let report = try FollowingDiagnostic.decode(Data(contentsOf: url.appendingPathComponent("report.json")))
        XCTAssertTrue(report.replay().isEmpty)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        var decisions = try XCTUnwrap(json["decisions"] as? [[String: Any]])
        let legacyDecisions = decisions.map { decision -> [String: Any] in
            var decision = decision
            var tracker = decision["tracker"] as! [String: Any]
            tracker.removeValue(forKey: "tempoConfirmed")
            decision["tracker"] = tracker
            return decision
        }
        var legacy = json; legacy["decisions"] = legacyDecisions
        XCTAssertEqual(try FollowingDiagnostic.decode(JSONSerialization.data(withJSONObject: legacy)).decisions.count, decisions.count)
        var invalidTracker = try XCTUnwrap(decisions[0]["tracker"] as? [String: Any])
        invalidTracker["index"] = 999999
        decisions[0]["tracker"] = invalidTracker; json["decisions"] = decisions
        XCTAssertThrowsError(try FollowingDiagnostic.decode(JSONSerialization.data(withJSONObject: json)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("audio.wav").path))
        diagnostics.includeAudio = false
        XCTAssertTrue(try XCTUnwrap(diagnostics.snapshot()).1.isEmpty)
        diagnostics.save(); while diagnostics.saving { await Task.yield() }
        let silentURL = try XCTUnwrap(diagnostics.savedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: silentURL.appendingPathComponent("audio.wav").path))
        XCTAssertNil(try XCTUnwrap(diagnostics.snapshot()).0.audioStart)
    }
}
