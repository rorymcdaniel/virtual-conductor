import XCTest
import AVFoundation
import ConductorCore
@testable import VirtualConductor

@MainActor final class FollowingPerformanceTests: XCTestCase {
    private func perform(onsets: [Double], midi: MIDIFile? = nil) async throws -> FollowingDiagnostic {
        let midi = try midi ?? FollowingFixture.midi()
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(midi.duration*8000)))!
        source.frameLength = source.frameCapacity
        source.floatChannelData![0].initialize(repeating: 0, count: Int(source.frameLength))
        let prepared = try PreparedPerformance(midi: midi, source: source, preparation: 0, passages: [])
        let input = FollowingTestInput(), audio = FollowingTestAudio()
        let diagnostics = FollowingDiagnostics(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var now = 0.0
        let following = LiveFollowing(diagnostics: diagnostics, capture: input, clock: { now }, permission: { true }, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let plan = try FollowingPlan(score: FollowingFixture.score(silentMeasures: 0), solo: FollowingFixture.solo, waits: [], cadenzas: [])
        following.tolerance = 20
        try await following.start(prepared: prepared, plan: plan, audio: audio, position: 0)
        let pitches = [60,62,64,65]
        for frame in 1...Int((onsets.last!+0.3)*100) {
            now = Double(frame)*0.01
            audio.sourcePosition += 0.01*(audio.rates.last ?? 1)
            following.tick()
            let index = onsets.lastIndex { $0 <= now }
            following.observe(pitch: index.map { pitches[$0%4] }, time: now)
        }
        following.stop()
        while diagnostics.saving { await Task.yield() }
        defer { try? FileManager.default.removeItem(at: diagnostics.root) }
        return try XCTUnwrap(diagnostics.snapshot()).0
    }

    func testOneLateBreathDoesNotResetTheSharedPulse() async throws {
        var onsets = (0..<16).map { 0.5 + Double($0)*0.5 }
        onsets[6] += 0.06
        let report = try await perform(onsets: onsets)
        let commands = try XCTUnwrap(report.controls)
        let breath = commands.filter { $0.time >= 3.5 && $0.time <= 5 }
        XCTAssertLessThanOrEqual(try XCTUnwrap(breath.map(\.rate).max()), 1.05)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(breath.map(\.rate).min()), 0.95)
        XCTAssertEqual(try XCTUnwrap(commands.last).rate, 1, accuracy: 0.015)
        XCTAssertTrue(report.replayControls().isEmpty)
        let decoded = try FollowingDiagnostic.decode(report.encoded())
        XCTAssertEqual(decoded.controls?.count, commands.count)
        XCTAssertTrue(decoded.replayControls().isEmpty)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        legacy.removeValue(forKey: "controls")
        XCTAssertNil(try FollowingDiagnostic.decode(JSONSerialization.data(withJSONObject: legacy)).controls)
    }

    func testConsistentExpressiveTempoChangesStillReachPlayback() async throws {
        for pace in [0.84, 1.16] {
            var onsets = [0.5]
            for note in 1..<16 { onsets.append(onsets.last! + 0.5/(note < 4 ? 1 : pace)) }
            let report = try await perform(onsets: onsets)
            let commands = try XCTUnwrap(report.controls)
            XCTAssertEqual(try XCTUnwrap(commands.last).rate, pace, accuracy: 0.04)
            XCTAssertTrue(commands.allSatisfy { (0.8...1.2).contains($0.rate) })
            XCTAssertGreaterThan(report.decisions.filter { $0.matched != nil }.count, 12)
        }
    }

    func testRehearsalRegressionChecksFailWhenPlaybackViolatesTheMusicalExpectation() async throws {
        let report = try await perform(onsets: (0..<16).map { 0.5 + Double($0)*0.5 })
        func replay(maximum: Double, frozen: Bool = false, interrupted: Bool = false) throws -> FollowingRehearsalResult {
            let data = Data("""
            {"name":"Steady passage","report":"unused.json","source":"decisions",
             "fromQuarter":4,"toQuarter":12,"checkFromQuarter":8,"startingRate":1,
             "minimumRate":0.95,"maximumRate":\(maximum),"minimumMatches":3}
            """.utf8)
            var evidence = report
            if interrupted { evidence.notices.append(DiagnosticNotice(time: 5, reason: "Renamed lifecycle message", kind: .interruption)) }
            if frozen {
                evidence.decisions = report.decisions.map { event in
                    FollowingDecision(tracker: event.tracker, pitch: event.expectedQuarter >= 8 ? nil : event.pitch,
                        time: event.time, expectedQuarter: event.expectedQuarter, free: event.free,
                        throughQuarter: event.throughQuarter, rearticulated: event.rearticulated,
                        matched: event.matched, rate: event.rate, phase: event.phase, level: event.level)
                }
            }
            return try FollowingRehearsal.run(JSONDecoder().decode(FollowingRehearsalCase.self, from: data), report: evidence)
        }
        XCTAssertTrue(try replay(maximum: 1.05).passed)
        XCTAssertFalse(try replay(maximum: 0.96).passed)
        XCTAssertFalse(try replay(maximum: 1.05, frozen: true).passed)
        XCTAssertThrowsError(try replay(maximum: 1.05, interrupted: true))
    }

    func testWrittenRitardandoChangesTheBaselineWithoutUsingUpTolerance() async throws {
        var track: [UInt8] = []
        for note in 0..<16 {
            if note == 4 { track += [0,0xff,0x51,3,0x0a,0x2c,0x2b] } // 90 BPM
            if note == 8 { track += [0,0xff,0x51,3,0x07,0xa1,0x20] } // 120 BPM
            track += [0,0x90,60,90,0x83,0x60,0x80,60,0]
        }
        track += [0,0xff,0x2f,0]
        let n = track.count
        let midi = try MIDIFile(data: Data(Array("MThd".utf8)+[0,0,0,6,0,0,0,1,1,0xe0]+Array("MTrk".utf8)+[0,0,UInt8(n>>8),UInt8(n&255)]+track))
        var onsets = [0.5]
        for note in 1..<16 { onsets.append(onsets.last! + ((5...8).contains(note) ? 2.0/3 : 0.5)) }
        let report = try await perform(onsets: onsets, midi: midi)
        let commands = try XCTUnwrap(report.controls)
        XCTAssertTrue(commands.allSatisfy { (0.97...1.03).contains($0.rate) })
        XCTAssertTrue(commands.contains { abs($0.plannedBPM-90) < 0.01 })
        XCTAssertTrue(commands.contains { abs($0.plannedBPM-120) < 0.01 })
    }
}
