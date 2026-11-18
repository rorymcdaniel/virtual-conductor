import XCTest
import AVFoundation
import ConductorCore
@testable import VirtualConductor

final class MeasureStartTests: XCTestCase {
    @MainActor func testCarriedHeldNoteKeepsItsTimingWhenNormalPlaybackEntersFreePassage() async throws {
        let prepared = try FollowingFixture.prepared()
        let plan = try FollowingPlan(score: FollowingFixture.score(silentMeasures: 1, silentFrom: 2, sustainAcrossReturn: true), solo: FollowingFixture.solo,
            waits: [], freePassages: [PassageRange(start: 8, end: 12)], cadenzas: [])
        let audio = FollowingTestAudio(), input = FollowingTestInput()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = 0.0
        let following = LiveFollowing(diagnostics: FollowingDiagnostics(root: root), capture: input, clock: { now }, permission: { true })
        defer { following.stop() }
        try await following.start(prepared: prepared, plan: plan, audio: audio, position: 0)
        audio.sourcePosition = 4; now = 4; following.tick()
        following.observe(pitch: 65, time: 4); following.observe(pitch: 65, time: 4.03)
        following.observe(pitch: 65, time: 4.48)
        audio.sourcePosition = 4.5; now = 4.5; following.tick()
        now = 4.51; following.tick()
        XCTAssertEqual(following.position, 4.51, accuracy: 0.04, "Carrying a held note into free time must not add its elapsed time twice")
    }

    @MainActor func testTiedNoteAcrossChosenStartCannotMoveFreeFollowingBackIntoPreparation() async throws {
        let base = try FollowingFixture.prepared()
        let prepared = try PreparedPerformance(midi: base.midi, source: base.source, preparation: 1, passages: [], startMeasure: 3)
        let plan = try FollowingPlan(score: FollowingFixture.score(silentMeasures: 3, sustainAcrossReturn: true), solo: FollowingFixture.solo,
            waits: [], freePassages: [PassageRange(start: 0, end: 12)], cadenzas: [])
        let audio = FollowingTestAudio(), input = FollowingTestInput()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = 0.0
        let following = LiveFollowing(diagnostics: FollowingDiagnostics(root: root), capture: input, clock: { now }, permission: { true })
        defer { following.stop() }
        try await following.start(prepared: prepared, plan: plan, audio: audio, position: 0)
        audio.sourcePosition = 2.5; now = 2.5; following.tick()
        following.observe(pitch: 65, time: 2.52); following.observe(pitch: 65, time: 2.55)
        now = 2.56; following.tick()
        XCTAssertGreaterThanOrEqual(following.position, 2.5)
        XCTAssertEqual(prepared.timing.position(following.position).measure, 3)
        XCTAssertFalse(prepared.timing.position(following.position).preparing)
    }

    @MainActor func testSlightlyEarlyHeldEntranceAtSelectedStartReleasesItsWait() async throws {
        let base = try FollowingFixture.prepared()
        let prepared = try PreparedPerformance(midi: base.midi, source: base.source, preparation: 1, passages: [], startMeasure: 3)
        let plan = try FollowingPlan(score: FollowingFixture.score(silentMeasures: 0), solo: FollowingFixture.solo,
            waits: [WaitPoint(measure: 3, beat: 1)], cadenzas: [])
        let audio = FollowingTestAudio(), input = FollowingTestInput()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = 0.0
        let following = LiveFollowing(diagnostics: FollowingDiagnostics(root: root), capture: input, clock: { now }, permission: { true })
        defer { following.stop() }
        try await following.start(prepared: prepared, plan: plan, audio: audio, position: 0)
        audio.sourcePosition = 2.45; now = 2.45; following.tick()
        following.observe(pitch: 60, time: 2.45)
        following.observe(pitch: 60, time: 2.48)
        XCTAssertEqual(audio.appended.count, 1, "A correct entrance 50 ms early should queue the next buffer")
        audio.sourcePosition = 2.5; now = 2.5; following.tick()
        following.observe(pitch: 60, time: 2.51)
        XCTAssertEqual(following.status, .following)
    }

    func testLongRestCounterKeepsTheOriginalScoreLocationAfterJumping() throws {
        let score = try FollowingFixture.score(soloRestMeasures: [1, 2])
        let schedule = try LongRestSchedule(score: score, staffID: FollowingFixture.solo, threshold: 1)
        let timing = try PerformanceTiming(midi: FollowingFixture.midi(), preparatoryMeasures: 1, startMeasure: 3)
        let preparing = ConductorSnapshot(time: 2, segmentStart: 0, timing: timing, state: .running)
        XCTAssertNil(LongRestDisplay(snapshot: preparing, schedule: schedule).counter)
        let downbeat = ConductorSnapshot(time: 2.5, segmentStart: 0, timing: timing, state: .running)
        XCTAssertEqual(LongRestDisplay(snapshot: downbeat, schedule: schedule).counter, "2/2")
    }

    @MainActor func testStartInsideFreePassageListensAfterCountInAndCuesItsReturn() async throws {
        let base = try FollowingFixture.prepared()
        let prepared = try PreparedPerformance(midi: base.midi, source: base.source, preparation: 1, passages: [], startMeasure: 2)
        let plan = try FollowingPlan(score: FollowingFixture.score(), solo: FollowingFixture.solo,
            waits: [], freePassages: [PassageRange(start: 0, end: 8)], cadenzas: [])
        let audio = FollowingTestAudio(), input = FollowingTestInput()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = 0.0
        let following = LiveFollowing(diagnostics: FollowingDiagnostics(root: root), capture: input, clock: { now }, permission: { true })
        defer { following.stop() }
        try await following.start(prepared: prepared, plan: plan, audio: audio, position: 0)
        XCTAssertEqual(audio.played.first?.end, 2.5)
        audio.sourcePosition = 2.5; now = 2.5; following.tick()
        following.observe(pitch: 60, time: 2.52); following.observe(pitch: 60, time: 2.55)
        now = 2.56; following.tick()
        XCTAssertGreaterThanOrEqual(following.position, 2.5)
        XCTAssertEqual(prepared.timing.position(following.position).measure, 2)
        following.cue()
        XCTAssertEqual(audio.played.last?.position, 4.5)
        XCTAssertEqual(prepared.timing.position(following.position).measure, 3)
    }

    @MainActor func testPausedPracticeCanChooseAnotherMeasureAndResetKeepsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PerformanceModel(defaults: UserDefaults(suiteName: UUID().uuidString)!, takeLibrary: TakeLibrary(root: root))
        model.prepared = try FollowingFixture.prepared()
        model.preparation = 2; model.state = .paused
        defer { model.reset(); model.audio.shutdown() }
        for invalid in ["0", "5", "2.5", "", "99999999999999999999999"] {
            XCTAssertFalse(model.chooseStartMeasure(invalid))
            XCTAssertEqual(model.state, .paused)
            XCTAssertEqual(model.prepared?.timing.startMeasure, 1)
        }
        XCTAssertTrue(model.chooseStartMeasure("3"))
        for _ in 0..<200 where model.state == .loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.prepared?.timing.startMeasure, 3)
        XCTAssertEqual(model.prepared?.timing.prepBeats, 8)
        model.reset()
        XCTAssertEqual(model.prepared?.timing.startMeasure, 3)
        XCTAssertEqual(model.elapsed(), 0)
        XCTAssertTrue(model.chooseStartMeasure("1"))
        for _ in 0..<200 where model.state == .loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.prepared?.timing.startMeasure, 1)
        XCTAssertEqual(model.state, .ready)
    }

    @MainActor func testStartInsideCadenzaPreparesThenWaitsForItsOriginalReturn() async throws {
        let passage = CadenzaPassage(startMeasure: 1, startBeat: 2, returnMeasure: 3, returnBeat: 1)
        let base = try FollowingFixture.prepared(cadenzas: [passage])
        let prepared = try PreparedPerformance(midi: base.midi, source: base.source, preparation: 1, passages: [passage], startMeasure: 2)
        XCTAssertEqual(prepared.segments.first?.end, 2.5)
        XCTAssertEqual(prepared.segments.last?.position, 4.5)
        let plan = try FollowingPlan(score: FollowingFixture.score(), solo: FollowingFixture.solo,
            waits: [], cadenzas: prepared.passages)
        let input = FollowingTestInput(), audio = FollowingTestAudio()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = 0.0
        let following = LiveFollowing(diagnostics: FollowingDiagnostics(root: root), capture: input, clock: { now }, permission: { true })
        defer { following.stop() }
        try await following.start(prepared: prepared, plan: plan, audio: audio, position: 0)
        XCTAssertEqual(audio.played.first?.end, 2.5)
        audio.sourcePosition = 2.5; now = 2.5; following.tick()
        XCTAssertEqual(following.status, .cadenza)
        following.cue()
        XCTAssertEqual(audio.played.last?.position, 4.5)
        XCTAssertEqual(prepared.timing.position(following.position).measure, 3)
        let after = try PreparedPerformance(midi: base.midi, source: base.source, preparation: 1, passages: [passage], startMeasure: 3)
        XCTAssertTrue(after.passages.isEmpty)
        XCTAssertEqual(after.segments.count, 1)
    }

    @MainActor func testLiveStartBypassesEarlierWaitAndWaitsAtChosenMeasureAfterPreparation() async throws {
        let base = try FollowingFixture.prepared()
        let prepared = try PreparedPerformance(midi: base.midi, source: base.source, preparation: 1, passages: [], startMeasure: 3)
        let plan = try FollowingPlan(score: FollowingFixture.score(silentMeasures: 0), solo: FollowingFixture.solo,
            waits: [WaitPoint(measure: 2, beat: 1), WaitPoint(measure: 3, beat: 1)], cadenzas: [])
        let input = FollowingTestInput(), audio = FollowingTestAudio()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = 0.0
        let following = LiveFollowing(diagnostics: FollowingDiagnostics(root: root), capture: input, clock: { now }, permission: { true })
        defer { following.stop() }
        try await following.start(prepared: prepared, plan: plan, audio: audio, position: 0)
        XCTAssertEqual(audio.played.first?.end, 2.5)
        XCTAssertEqual(following.status, .following)
        audio.sourcePosition = 2.5; now = 2.5; following.tick()
        XCTAssertEqual(following.status, .waiting)
        following.cue()
        XCTAssertEqual(audio.played.last?.position, 2.5)
        XCTAssertEqual(prepared.timing.position(following.position).measure, 3)
    }

    func testLaterTempoAndAudioBeginAfterSilentPreparation() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "fractional-tempo", withExtension: "mid", subdirectory: "Fixtures"))
        let midi = try MIDIFile(data: Data(contentsOf: url))
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64000)!
        source.frameLength = 64000
        source.floatChannelData![0].initialize(repeating: 0.25, count: 64000)
        // Fixture: measure 2 is at 1.8125 seconds, after the tempo changes to 96.
        source.floatChannelData![0][14500] = 0.75
        source.floatChannelData![0][14501] = 0.5
        let prepared = try PreparedPerformance(midi: midi, source: source, preparation: 1, passages: [], startMeasure: 2)
        XCTAssertEqual(prepared.timing.position(0).bpm, 96)
        XCTAssertEqual(prepared.timing.prepSeconds, 3.125)
        let segment = try XCTUnwrap(prepared.segments.first)
        XCTAssertTrue((0..<25000).allSatisfy { segment.music.floatChannelData![0][$0] == 0 })
        XCTAssertEqual(segment.music.floatChannelData![0][25000], 0.75)
        XCTAssertEqual(segment.music.floatChannelData![0][25001], 0.5)
        XCTAssertNotEqual(segment.clicks.floatChannelData![0][5002], 0)
        XCTAssertNotEqual(segment.clicks.floatChannelData![0][25002], 0)
        XCTAssertEqual(prepared.timing.position(3.125).measure, 2)
        XCTAssertEqual(prepared.timing.musicalEnd, 5.625)
        XCTAssertEqual(prepared.end, 9.3125)
    }

    func testSelectedMeasureReceivesFullPreparationBeforeItsOriginalScorePosition() throws {
        let midi = try FollowingFixture.midi()
        let timing = try PerformanceTiming(midi: midi, preparatoryMeasures: 2, startMeasure: 3)
        XCTAssertEqual(timing.prepSeconds, 4.5)
        XCTAssertTrue(timing.position(0).leadIn)
        XCTAssertEqual(timing.position(0.5).measure, -2)
        XCTAssertEqual(timing.position(2.5).measure, -1)
        XCTAssertEqual(timing.position(4.5).measure, 3)
        XCTAssertEqual(timing.position(4.5).beat, 0)
        XCTAssertEqual(timing.position(6.5).measure, 4)
        XCTAssertEqual(timing.musicalEnd, 8.5)
        XCTAssertEqual(timing.totalBeats, 16)
    }
}
