import XCTest
import AVFoundation
import ConductorCore
@testable import VirtualConductor

enum FollowingFixture {
    static func score(silentMeasures: Int = 2, silentFrom: Int = 0, transpose: Int = 0, restAcrossReturn: Bool = false, sustainAcrossReturn: Bool = false) throws -> MusicXMLScore {
        let names = ["C", "D", "E", "F"]
        let attributes = "<attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time><transpose><chromatic>\(transpose)</chromatic></transpose></attributes>"
        let solo = (0..<4).map { m in
            "<measure number=\"\(m+1)\">" + (m == 0 ? attributes : "") + names.enumerated().map { beat, name in
                if restAcrossReturn && ((m == 1 && beat == 3) || (m == 2 && beat == 0)) { return "<note><rest/><duration>1</duration></note>" }
                if sustainAcrossReturn && ((m == 1 && beat == 3) || (m == 2 && beat == 0)) {
                    return "<note><pitch><step>F</step><octave>4</octave></pitch><duration>1</duration><tie type=\"\(m == 1 ? "start" : "stop")\"/></note>"
                }
                return "<note><pitch><step>\(name)</step><octave>4</octave></pitch><duration>1</duration></note>"
            }.joined() + "</measure>"
        }.joined()
        let orchestra = (0..<4).map { m in
            "<measure number=\"\(m+1)\">" + (m == 0 ? attributes : "") + "<note>" +
            ((silentFrom..<(silentFrom + silentMeasures)).contains(m) ? "<rest/>" : "<pitch><step>C</step><octave>3</octave></pitch>") + "<duration>4</duration></note></measure>"
        }.joined()
        return try MusicXMLScore(data: Data("<score-partwise><part-list><score-part id=\"S\"><part-name>Solo</part-name></score-part><score-part id=\"O\"><part-name>Orchestra</part-name></score-part></part-list><part id=\"S\">\(solo)</part><part id=\"O\">\(orchestra)</part></score-partwise>".utf8))
    }
    static var solo: MusicXMLStaffID { MusicXMLStaffID(partID: "S", staffNumber: 1) }
    static func midi() throws -> MIDIFile {
        var track: [UInt8] = []
        for _ in 0..<16 { track += [0, 0x90, 60, 90, 0x83, 0x60, 0x80, 60, 0] }
        track += [0, 0xff, 0x2f, 0]
        let n = track.count
        return try MIDIFile(data: Data(Array("MThd".utf8) + [0,0,0,6,0,0,0,1,1,0xe0] + Array("MTrk".utf8) + [0,0,UInt8(n >> 8),UInt8(n & 255)] + track))
    }
    static func prepared(cadenzas: [CadenzaPassage] = []) throws -> PreparedPerformance {
        let midi = try midi(), format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64000)!
        source.frameLength = 64000; source.floatChannelData![0].initialize(repeating: 0, count: 64000)
        return try PreparedPerformance(midi: midi, source: source, preparation: 0, passages: cadenzas)
    }
}

final class SoloFollowingTests: XCTestCase {
    func testHeldPitchDoesNotJumpAcrossInterveningNotesOnAnAmplitudeAccent() throws {
        let notes = [60, 62, 64, 60].enumerated().map { MIDINote(pitch: $1, startQuarter: Double($0), endQuarter: Double($0 + 1)) }
        let midi = try FollowingFixture.midi()
        var tracker = SoloTracker()
        for t in [0.0, 0.03] { _ = tracker.observe(pitch: 60, time: t, notes: notes, expectedQuarter: 0, free: false, midi: midi) }
        _ = tracker.observe(pitch: 60, time: 0.2, notes: notes, expectedQuarter: 0.4, free: false, midi: midi, rearticulated: true)
        XCTAssertEqual(tracker.index, 0)
    }

    func testWrongFreePassagePitchCannotJumpToADistantOrchestralReturn() throws {
        let notes = (0..<7).map { MIDINote(pitch: 60+$0, startQuarter: Double($0), endQuarter: Double($0+1)) }
        let midi = try FollowingFixture.midi()
        var tracker = SoloTracker()
        for t in [0.0, 0.03] {
            _ = tracker.observe(pitch: 65, time: t, notes: notes, expectedQuarter: 0, free: true, midi: midi, throughQuarter: 5)
        }
        XCTAssertNil(tracker.index)
        tracker.reset(notes: notes, quarter: 4)
        for t in [3.0, 3.03] {
            _ = tracker.observe(pitch: 66, time: t, notes: notes, expectedQuarter: 4, free: true, midi: midi, throughQuarter: 5)
        }
        XCTAssertNil(tracker.index)
    }

    func testSteadyLeadInKeepsTheOrchestraAlignedThroughAHeldReturnNote() throws {
        let midi = try FollowingFixture.midi()
        let beats = [0.0, 2, 4, 4 + 1.0/3, 4 + 2.0/3, 5, 9]
        let notes = zip(beats, beats.dropFirst()).enumerated().map {
            MIDINote(pitch: 60 + $0.offset, startQuarter: $0.element.0, endQuarter: $0.element.1)
        }
        for pace in [0.94, 1.06, 1.6] {
            var tracker = SoloTracker(), tempo = FollowingTempo()
            for note in notes {
                let onset = midi.seconds(atQuarter: note.startQuarter) / pace
                for t in [onset, onset + 0.015] {
                    tracker.observe(pitch: note.pitch, time: t, notes: notes, expectedQuarter: note.startQuarter, free: true, midi: midi)
                }
            }
            let scoreTime = midi.seconds(atQuarter: 5)
            tracker.beginAccompaniedPhrase(scoreTime: scoreTime, tolerance: 0.1)
            XCTAssertEqual(tempo.rate, 1)
            if pace > 1.1 {
                XCTAssertEqual(tracker.rate, 1, "Extreme rubato must not set the return tempo")
                continue
            }
            var position = scoreTime
            for frame in 1...90 {
                let elapsed = Double(frame) * 0.02
                let target = scoreTime + (elapsed + 0.035) * pace
                let rate = tempo.update(delta: 0.02, tolerance: 0.1, trackedRate: tracker.rate,
                                        phaseError: target - position, age: 0)
                XCTAssertTrue((0.9...1.1).contains(rate))
                position += 0.02 * rate
                XCTAssertLessThan(abs(position - target), 0.055)
            }
        }
    }

    func testShortReturnConfirmationRequiresTheExpectedPitchInBothWindows() {
        let rate = 12000.0
        func signal(_ pitch: Int, _ count: Int) -> [Float] {
            let hz = 440 * pow(2, Double(pitch - 69) / 12)
            return (0..<count).map { Float(0.15 * sin(2 * .pi * hz * Double($0) / rate)) }
        }
        XCTAssertTrue(LivePitch.confirmsReturn(70, samples: signal(70, 540), sampleRate: rate))
        XCTAssertFalse(LivePitch.confirmsReturn(70, samples: signal(58, 540), sampleRate: rate))
        XCTAssertFalse(LivePitch.confirmsReturn(70, samples: signal(58, 420) + signal(70, 120), sampleRate: rate))
    }

    func testTripletTempoUsesThePhraseDespiteFrameTimingJitter() throws {
        let midi = try FollowingFixture.midi(), pace = 0.94
        let notes = (0..<8).map { MIDINote(pitch: 60 + $0, startQuarter: Double($0)/3, endQuarter: Double($0+1)/3) }
        var tracker = SoloTracker()
        for (i, note) in notes.enumerated() {
            let onset = midi.seconds(atQuarter: note.startQuarter) / pace + (i.isMultiple(of: 2) ? 0 : 0.025)
            for t in [onset, onset + 0.02] { _ = tracker.observe(pitch: note.pitch, time: t, notes: notes, expectedQuarter: note.startQuarter, free: false, midi: midi) }
        }
        XCTAssertEqual(tracker.index, 7)
        XCTAssertEqual(tracker.rate, pace, accuracy: 0.04)
    }
    func testConcertPitchAndAutomaticSilence() throws {
        let score = try FollowingFixture.score(transpose: -7)
        let plan = try FollowingPlan(score: score, solo: FollowingFixture.solo, waits: [WaitPoint(measure: 1, beat: 2)], cadenzas: [])
        XCTAssertEqual(plan.notes.prefix(4).map(\.pitch), [53,55,57,58])
        XCTAssertEqual(plan.waits, [1])
        XCTAssertEqual(plan.freePassages, [PassageRange(start: 0, end: 8)])
        XCTAssertThrowsError(try FollowingPlan(score: score, solo: FollowingFixture.solo, waits: [WaitPoint(measure: 1, beat: 1.5)], cadenzas: []))
        XCTAssertThrowsError(try FollowingPlan(score: score, solo: FollowingFixture.solo, waits: [WaitPoint(measure: 0, beat: 1)], cadenzas: []))
    }
    func testCadenzaOverridesAutomaticFreeFollowing() throws {
        let midi = try FollowingFixture.midi()
        let cadenzas = try compileCadenzas([CadenzaPassage(startMeasure: 1, startBeat: 1, returnMeasure: 2, returnBeat: 1)], midi: midi, audioDuration: 8)
        let plan = try FollowingPlan(score: FollowingFixture.score(), solo: FollowingFixture.solo, waits: [], cadenzas: cadenzas)
        XCTAssertEqual(plan.freePassages, [PassageRange(start: 4, end: 8)])
    }
    func testTrackerToleratesWrongAndSkippedNotesWithoutAdvancingOnHeldPitch() throws {
        let notes = try FollowingFixture.score().staves[0].notes, midi = try FollowingFixture.midi()
        var tracker = SoloTracker()
        tracker.reset(notes: notes, quarter: 0)
        func observe(_ pitch: Int?, _ time: Double) -> Int? {
            _ = tracker.observe(pitch: pitch, time: time, notes: notes, expectedQuarter: 0, free: true, midi: midi)
            return tracker.observe(pitch: pitch, time: time + 0.03, notes: notes, expectedQuarter: 0, free: true, midi: midi)
        }
        XCTAssertEqual(observe(60, 0), 0)
        XCTAssertNil(observe(61, 1))
        XCTAssertEqual(observe(64, 2), 2) // missed D
        XCTAssertNil(observe(64, 20)) // held indefinitely, no invented progress
        XCTAssertEqual(tracker.index, 2)
        XCTAssertNil(observe(nil, 21))
        XCTAssertEqual(observe(65, 22), 3)
    }
    func testToleranceAndSmoothRecoveryNeverJump() {
        var tempo = FollowingTempo()
        for _ in 0..<100 {
            let rate = tempo.update(delta: 0.02, tolerance: 0.1, trackedRate: 0.2, phaseError: -5, age: 0)
            XCTAssertGreaterThanOrEqual(rate, 0.9); XCTAssertLessThanOrEqual(rate, 1.1)
        }
        let slow = tempo.rate
        XCTAssertEqual(tempo.update(delta: 0.02, tolerance: 0.1, trackedRate: 2, phaseError: 3, age: 1), slow)
        for _ in 0..<150 { _ = tempo.update(delta: 0.02, tolerance: 0.1, trackedRate: 2, phaseError: 3, age: 3) }
        XCTAssertEqual(tempo.rate, 1, accuracy: 0.001)
    }
    func testLivePitchDetectsInstrumentDominantOverLeakageAndRejectsSilence() {
        let rate = 48000.0
        for pitch in [48, 53, 60, 69, 77] {
            let frequency = 440 * pow(2, Double(pitch - 69) / 12)
            let samples = (0..<3600).map { i -> Float in
                let t = Double(i) / rate
                return Float(0.15 * sin(2 * .pi * frequency * t) + 0.05 * sin(4 * .pi * frequency * t) + 0.004 * sin(2 * .pi * 233 * t))
            }
            XCTAssertEqual(LivePitch.detect(samples: samples, sampleRate: rate), pitch)
        }
        XCTAssertNil(LivePitch.detect(samples: [Float](repeating: 0, count: 3600), sampleRate: rate))
    }
    func testLiveQueueIsBoundedAndRecoversAfterOverflow() {
        let stream = LiveSampleBuffer()
        for i in 0..<40000 { stream.write(Float(i)) }
        let first = stream.drain()
        XCTAssertEqual(first.count, 32768); XCTAssertEqual(first.last, 32767)
        XCTAssertEqual(stream.dropped.load(ordering: .acquiring), 7232)
        stream.write(42); XCTAssertEqual(stream.drain(), [42]); XCTAssertTrue(stream.drain().isEmpty)
    }
    func testRepeatedPitchNeedsArticulationAndOrdinaryDynamicsDoNotInventAttacks() throws {
        let notes = [MIDINote(pitch: 60, startQuarter: 0, endQuarter: 1), MIDINote(pitch: 60, startQuarter: 1, endQuarter: 2)]
        let midi = try FollowingFixture.midi()
        var tracker = SoloTracker(), articulation = LiveArticulation()
        _ = tracker.observe(pitch: 60, time: 0, notes: notes, expectedQuarter: 0, free: true, midi: midi)
        _ = tracker.observe(pitch: 60, time: 0.03, notes: notes, expectedQuarter: 0, free: true, midi: midi)
        for i in 0..<30 {
            XCTAssertFalse(articulation.observe(rms: i % 2 == 0 ? 0.1 : 0.08, time: Double(i) * 0.01))
        }
        XCTAssertFalse(articulation.observe(rms: 0.01, time: 0.5))
        XCTAssertTrue(articulation.observe(rms: 0.1, time: 0.51))
        XCTAssertNil(tracker.observe(pitch: 60, time: 0.52, notes: notes, expectedQuarter: 1, free: true, midi: midi))
        XCTAssertEqual(tracker.observe(pitch: 60, time: 0.55, notes: notes, expectedQuarter: 1, free: true, midi: midi, rearticulated: true), 1)
    }
}

@MainActor private final class FollowingTestInput: FollowingInput {
    var storage: CaptureStorage?
    var sampleRate = 8000.0
    var ready = false
    var interrupted: (() -> Void)?
    func enable(device: UInt32, streaming: Bool) throws { ready = true }
    func release() { ready = false }
}
@MainActor private final class FollowingTestAudio: FollowingAudio {
    var played: [AudioSegment] = []
    var appended: [AudioSegment] = []
    var sourcePosition = 0.0
    var rates: [Double] = []
    var stops = 0
    func play(_ segment: AudioSegment, immediate: Bool) throws { played.append(segment); sourcePosition = segment.position }
    func append(_ segment: AudioSegment) { appended.append(segment) }
    func stop() { stops += 1 }
    func setRate(_ rate: Double) { rates.append(rate) }
    func position(host: Double) -> Double { sourcePosition }
}

@MainActor final class LiveFollowingTests: XCTestCase {
    func testRenderedReleaseContinuesWhenAutomaticFreeFollowingBegins() async throws {
        let input = FollowingTestInput(), audio = FollowingTestAudio(), prepared = try FollowingFixture.prepared()
        // The written accompaniment ends at 2 seconds, but its WAV still rings.
        let start = 16000, frames = 2000
        for i in 0..<frames { prepared.source.floatChannelData![0][start+i] = 0.1 * Float(frames-i)/Float(frames) }
        let plan = try FollowingPlan(score: FollowingFixture.score(silentFrom: 1), solo: FollowingFixture.solo, waits: [], cadenzas: [])
        let follower = LiveFollowing(capture: input, permission: { true })
        try await follower.start(prepared: prepared, plan: plan, audio: audio, position: 0)
        let segment = try XCTUnwrap(audio.played.first)
        let boundary = Int(segment.clicks.frameLength)
        XCTAssertGreaterThanOrEqual(Int(segment.music.frameLength), boundary + frames)
        if Int(segment.music.frameLength) > boundary + frames/2 {
            XCTAssertEqual(segment.music.floatChannelData![0][boundary + frames/2], 0.05, accuracy: 0.0001)
        }
        let stops = audio.stops
        audio.sourcePosition = segment.end
        follower.tick()
        XCTAssertEqual(audio.stops, stops)
        XCTAssertEqual(audio.played.count, 1)
    }
    func testReturnInsideHeldNoteRequestsPedalInsteadOfGuessingRubato() async throws {
        let input = FollowingTestInput(), audio = FollowingTestAudio(), prepared = try FollowingFixture.prepared()
        var now = 0.0
        let following = LiveFollowing(capture: input, clock: { now }, permission: { true })
        let plan = try FollowingPlan(score: FollowingFixture.score(sustainAcrossReturn: true), solo: FollowingFixture.solo, waits: [], cadenzas: [])
        try await following.start(prepared: prepared, plan: plan, audio: audio, position: 0)
        audio.sourcePosition = 0.5; now = 0.5; following.tick()
        for pitch in [60,62,64,65,60,62,64,65] {
            now += 0.4
            following.observe(pitch: pitch, time: now); following.observe(pitch: pitch, time: now + 0.03)
            following.tick()
        }
        XCTAssertEqual(following.status, .waiting)
        XCTAssertTrue(following.detail.contains("Held note")); XCTAssertEqual(audio.played.count, 1)
        following.cue(); XCTAssertEqual(audio.played.last?.position, 4.5)
    }
    func testFreePassageWithSoloRestCountsToReturnAtPlannedTempo() async throws {
        let input = FollowingTestInput(), audio = FollowingTestAudio(), prepared = try FollowingFixture.prepared()
        var now = 0.0
        let following = LiveFollowing(capture: input, clock: { now }, permission: { true })
        let plan = try FollowingPlan(score: FollowingFixture.score(restAcrossReturn: true), solo: FollowingFixture.solo, waits: [], cadenzas: [])
        try await following.start(prepared: prepared, plan: plan, audio: audio, position: 0)
        audio.sourcePosition = 0.5; now = 0.5; following.tick()
        for pitch in [60,62,64,65,60,62,64] {
            now += 1
            following.observe(pitch: pitch, time: now); following.observe(pitch: pitch, time: now + 0.03)
            following.tick()
        }
        following.observe(pitch: 64, time: 19.9)
        following.observe(pitch: nil, time: 20); following.observe(pitch: nil, time: 20.03)
        now = 20.4; following.observe(pitch: nil, time: now); following.tick()
        XCTAssertEqual(audio.played.count, 1)
        now = 20.6; following.observe(pitch: nil, time: now); following.tick()
        XCTAssertEqual(audio.played.last?.position, 4.5); XCTAssertEqual(audio.rates.last, 1)
    }
    func testExplicitWaitInsideFreePassageCannotBeSkippedByPhraseMatching() async throws {
        let input = FollowingTestInput(), audio = FollowingTestAudio(), prepared = try FollowingFixture.prepared()
        var now = 0.0
        let following = LiveFollowing(capture: input, clock: { now }, permission: { true })
        let plan = try FollowingPlan(score: FollowingFixture.score(), solo: FollowingFixture.solo,
                                     waits: [WaitPoint(measure: 1, beat: 2)], cadenzas: [])
        try await following.start(prepared: prepared, plan: plan, audio: audio, position: 0)
        audio.sourcePosition = 0.5; now = 0.5; following.tick()
        following.observe(pitch: 60, time: 0.6); following.observe(pitch: 60, time: 0.63)
        following.observe(pitch: 64, time: 1); following.observe(pitch: 64, time: 1.03)
        XCTAssertEqual(following.status, .waiting); XCTAssertEqual(following.position, 1)
        following.observe(pitch: 62, time: 2); following.observe(pitch: 62, time: 2.03)
        XCTAssertEqual(audio.played.count, 1) // still in orchestral silence
        following.cue(); XCTAssertEqual(audio.played.last?.position, 4.5)
    }
    func testSyntheticMicrophoneStreamReleasesExpectedEntrance() async throws {
        let input = FollowingTestInput(), audio = FollowingTestAudio(), prepared = try FollowingFixture.prepared()
        var now = 0.0
        let following = LiveFollowing(capture: input, clock: { now }, permission: { true })
        let plan = try FollowingPlan(score: FollowingFixture.score(silentMeasures: 0), solo: FollowingFixture.solo,
                                     waits: [WaitPoint(measure: 1, beat: 1)], cadenzas: [])
        try await following.start(prepared: prepared, plan: plan, audio: audio, position: 0)
        input.storage = CaptureStorage(rate: 8000, streaming: true)
        audio.sourcePosition = 0.5; now = 0.5; following.tick()
        for block in 0..<6 {
            for i in 0..<800 {
                let t = Double(block * 800 + i) / 8000
                input.storage?.stream?.write(Float(0.1 * sin(2 * .pi * 261.6256 * t) + 0.002 * sin(2 * .pi * 233 * t)))
            }
            now += 0.1; following.tick()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(audio.played.count, 2)
        XCTAssertEqual(audio.played.last?.position, 0.5)
        following.stop()
    }
    func testHeldEarlierPitchDoesNotReleaseLaterWait() async throws {
        let input = FollowingTestInput(), audio = FollowingTestAudio(), prepared = try FollowingFixture.prepared()
        var now = 0.0
        let following = LiveFollowing(capture: input, clock: { now }, permission: { true })
        let plan = try FollowingPlan(score: FollowingFixture.score(silentMeasures: 0), solo: FollowingFixture.solo,
                                     waits: [WaitPoint(measure: 2, beat: 1)], cadenzas: [])
        try await following.start(prepared: prepared, plan: plan, audio: audio, position: 0)
        following.observe(pitch: 60, time: 0.5); following.observe(pitch: 60, time: 0.53)
        audio.sourcePosition = 2.5; now = 2.5; following.tick()
        following.observe(pitch: 60, time: now); following.observe(pitch: 60, time: now + 0.03)
        XCTAssertEqual(audio.played.count, 1)
        following.observe(pitch: 60, time: now + 0.2, rearticulated: true)
        XCTAssertEqual(audio.played.count, 2)
    }
    func testLostFreeFollowingStaysSilentThroughSubsequentSilenceUntilPedal() async throws {
        let input = FollowingTestInput(), audio = FollowingTestAudio(), prepared = try FollowingFixture.prepared()
        var now = 0.0
        let following = LiveFollowing(capture: input, clock: { now }, permission: { true })
        let plan = try FollowingPlan(score: FollowingFixture.score(), solo: FollowingFixture.solo, waits: [], cadenzas: [])
        try await following.start(prepared: prepared, plan: plan, audio: audio, position: 0)
        audio.sourcePosition = 0.5; now = 0.5; following.tick()
        following.observe(pitch: 61, time: now); following.observe(pitch: 61, time: now + 0.03)
        now = 1; following.tick(); XCTAssertEqual(following.status, .lost)
        now = 20; following.observe(pitch: nil, time: now); following.tick()
        XCTAssertEqual(following.status, .lost); XCTAssertEqual(audio.played.count, 1)
        following.cue(); XCTAssertEqual(audio.played.last?.position, 4.5)
    }
    func testStopWhilePermissionPendingCannotStartMicrophoneOrPlayback() async throws {
        let input = FollowingTestInput(), audio = FollowingTestAudio(), prepared = try FollowingFixture.prepared()
        var permission: CheckedContinuation<Bool, Never>?
        let following = LiveFollowing(capture: input, permission: { await withCheckedContinuation { permission = $0 } })
        let plan = try FollowingPlan(score: FollowingFixture.score(), solo: FollowingFixture.solo, waits: [], cadenzas: [])
        let task = Task { try await following.start(prepared: prepared, plan: plan, audio: audio, position: 0) }
        while permission == nil { await Task.yield() }
        following.stop(); permission?.resume(returning: true)
        do { try await task.value; XCTFail("Cancelled start succeeded") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertFalse(input.ready); XCTAssertFalse(following.active); XCTAssertTrue(audio.played.isEmpty)
    }
    func testWaitRequiresExpectedAttackAndPedalOverrides() async throws {
        let input = FollowingTestInput(), audio = FollowingTestAudio(), prepared = try FollowingFixture.prepared()
        var now = 0.0
        let following = LiveFollowing(capture: input, clock: { now }, permission: { true })
        let plan = try FollowingPlan(score: FollowingFixture.score(silentMeasures: 0), solo: FollowingFixture.solo,
                                     waits: [WaitPoint(measure: 1, beat: 1), WaitPoint(measure: 1, beat: 2)], cadenzas: [])
        try await following.start(prepared: prepared, plan: plan, audio: audio, position: 0)
        audio.sourcePosition = prepared.timing.prepSeconds; now = 0.5; following.tick()
        XCTAssertEqual(following.status, .waiting)
        following.observe(pitch: 64, time: now); following.observe(pitch: 64, time: now + 0.03)
        XCTAssertEqual(audio.played.count, 1)
        following.observe(pitch: 60, time: now + 0.06); following.observe(pitch: 60, time: now + 0.09)
        XCTAssertEqual(audio.played.count, 2)
        audio.sourcePosition = prepared.timing.prepSeconds + 0.5; now = 1; following.tick()
        XCTAssertEqual(following.status, .waiting)
        following.cue()
        XCTAssertEqual(audio.played.last?.position, 1)
        following.stop(); XCTAssertFalse(input.ready)
    }
    func testOnTimeEntranceQueuesContinuousAudio() async throws {
        let input = FollowingTestInput(), audio = FollowingTestAudio(), prepared = try FollowingFixture.prepared()
        var now = 0.0
        let following = LiveFollowing(capture: input, clock: { now }, permission: { true })
        let plan = try FollowingPlan(score: FollowingFixture.score(silentMeasures: 0), solo: FollowingFixture.solo,
                                     waits: [WaitPoint(measure: 1, beat: 2)], cadenzas: [])
        try await following.start(prepared: prepared, plan: plan, audio: audio, position: 0)
        audio.sourcePosition = 0.9; now = 0.9; following.tick()
        following.observe(pitch: 62, time: now); following.observe(pitch: 62, time: now + 0.03)
        XCTAssertEqual(audio.appended.count, 1)
        let stops = audio.stops
        audio.sourcePosition = 1; now = 1; following.tick()
        XCTAssertEqual(audio.stops, stops); XCTAssertEqual(audio.played.count, 1)
    }
    func testFreeFollowingWaitsThroughPauseAndReturnsAtPlannedTempo() async throws {
        let input = FollowingTestInput(), audio = FollowingTestAudio(), prepared = try FollowingFixture.prepared()
        var now = 0.0
        let following = LiveFollowing(capture: input, clock: { now }, permission: { true })
        let plan = try FollowingPlan(score: FollowingFixture.score(), solo: FollowingFixture.solo, waits: [], cadenzas: [])
        try await following.start(prepared: prepared, plan: plan, audio: audio, position: 0)
        audio.sourcePosition = 0.5; now = 0.5; following.tick()
        XCTAssertEqual(following.status, .waiting)
        following.observe(pitch: 60, time: now); following.observe(pitch: 60, time: now + 0.03)
        following.observe(pitch: nil, time: 1); following.observe(pitch: nil, time: 1.03)
        now = 40; following.observe(pitch: nil, time: now); following.tick()
        XCTAssertEqual(audio.played.count, 1); XCTAssertEqual(following.status, .waiting)
        for pitch in [62,64,65,60,62,64,65,60] {
            now += 0.3
            following.observe(pitch: pitch, time: now); following.observe(pitch: pitch, time: now + 0.03)
            following.tick()
        }
        XCTAssertEqual(audio.played.count, 2)
        XCTAssertEqual(audio.played.last?.position, 4.5)
        XCTAssertEqual(audio.rates.last, 1)
    }
    func testCadenzaIgnoresMicrophoneAndInputLossStopsCapture() async throws {
        let input = FollowingTestInput(), audio = FollowingTestAudio()
        let prepared = try FollowingFixture.prepared(cadenzas: [CadenzaPassage(startMeasure: 1, startBeat: 1, returnMeasure: 3, returnBeat: 1)])
        var now = 0.0
        let following = LiveFollowing(capture: input, clock: { now }, permission: { true })
        let plan = try FollowingPlan(score: FollowingFixture.score(), solo: FollowingFixture.solo, waits: [WaitPoint(measure: 1, beat: 1)], cadenzas: prepared.passages)
        try await following.start(prepared: prepared, plan: plan, audio: audio, position: 0)
        audio.sourcePosition = 0.5; now = 0.5; following.tick()
        XCTAssertEqual(following.status, .cadenza)
        following.observe(pitch: 60, time: now); following.observe(pitch: 60, time: now + 0.03)
        XCTAssertEqual(audio.played.count, 1)
        following.cue(); XCTAssertEqual(audio.played.last?.position, 4.5)
        var failed = false; following.failed = { _ in failed = true }
        input.interrupted?()
        XCTAssertTrue(failed); XCTAssertFalse(following.active); XCTAssertFalse(input.ready)
    }
}
