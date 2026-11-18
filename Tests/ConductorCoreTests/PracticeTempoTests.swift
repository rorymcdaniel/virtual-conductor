import XCTest
import AVFoundation
import ConductorCore
@testable import VirtualConductor

final class PracticeTempoTests: XCTestCase {
    func testMarkInsideRallentandoSurvivesGeneratedStepsUntilWrittenOrLocalMark() throws {
        let xml = """
        <score-partwise><part-list><score-part id="S"><part-name>Solo</part-name></score-part></part-list>
        <part id="S"><measure number="1"><attributes><divisions>2</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>
        <direction><direction-type><words>rall.</words></direction-type><direction-type><dashes type="start"/></direction-type></direction>
        <note><rest/><duration>8</duration></note><direction><direction-type><dashes type="stop"/></direction-type></direction></measure>
        <measure number="2"><direction><offset>1</offset><sound tempo="100"/></direction><note><rest/><duration>8</duration></note></measure>
        </part></score-partwise>
        """
        let score = try MusicXMLScore(data: Data(xml.utf8))
        XCTAssertEqual(score.tempoDirectionQuarters, [0])
        // The first four MIDI events are steps in one written rallentando.
        let midi = try MIDIFile(data: rampMIDI())
        let boundaries = midi.practiceTempoBoundaries(score: score)
        XCTAssertEqual(boundaries, [0, 4.5])
        let marks = [PracticeTempoMark(quarter: 1.5, bpm: 80), PracticeTempoMark(quarter: 3.5, bpm: 90)]
        let map = try midi.applyingTempoMarks(marks, boundaries: boundaries)
        func bpm(_ q: Double) -> Double { map.tempo(atSeconds: map.seconds(atQuarter: q)) }
        XCTAssertEqual(bpm(1), 60 / 0.525, accuracy: 1e-8)
        XCTAssertEqual(bpm(2), 80)
        XCTAssertEqual(bpm(4), 90)
        XCTAssertEqual(bpm(4.5), 100)
        let timing = try PerformanceTiming(midi: midi, preparatoryMeasures: 0)
        let practice = try PracticeTempo(timing: timing, marks: marks, boundaries: boundaries)
        XCTAssertEqual(practice.entries.map(\.quarter), [0, 1, 1.5, 3.5, 4.5])
        XCTAssertEqual(practice.entries.map(\.source), [.score, .playback, .practice, .practice, .score])
        XCTAssertEqual(practice.entries.map(\.bpm), practice.entries.map { bpm($0.quarter) })
        let replaced = try midi.applyingTempoMarks(marks + [PracticeTempoMark(quarter: 4.5, bpm: 91)], boundaries: boundaries)
        XCTAssertEqual(replaced.tempo(atSeconds: replaced.duration), 91, accuracy: 1e-8)
        XCTAssertThrowsError(try midi.applyingTempoMarks([.init(quarter: 16, bpm: 70)], boundaries: boundaries))
    }

    func testDeletingOneEntryOrAnEntireRampCarriesThePrecedingTempo() throws {
        let midi = try MIDIFile(data: rampMIDI())
        let timing = try PerformanceTiming(midi: midi, preparatoryMeasures: 0)
        func map(_ edits: PracticeTempo.Edits) throws -> PracticeTempo {
            try PracticeTempo(timing: timing, marks: edits.marks, boundaries: [0, 1, 4.5], deleted: edits.deleted)
        }
        let original = try map(.init(marks: [.init(quarter: 0.5, bpm: 84)]))
        let ramp = try XCTUnwrap(original.entries.first { $0.quarter == 1 })
        let single = try map(original.deleting(ramp, includingTempoSteps: false))
        XCTAssertEqual(single.bpm(atQuarter: 1), 84)
        XCTAssertEqual(single.nextMark(after: 0.5), 2)
        XCTAssertEqual(single.bpm(atQuarter: 2), midi.tempo(atQuarter: 2))
        XCTAssertFalse(single.entries.contains { $0.quarter == 1 })
        let step = try XCTUnwrap(single.entries.first { $0.quarter == 2 })
        let twice = try map(single.deleting(step, includingTempoSteps: false))
        XCTAssertEqual(twice.bpm(atQuarter: 2), 84)
        XCTAssertEqual(twice.bpm(atQuarter: 3), midi.tempo(atQuarter: 3))

        let group = try map(original.deleting(ramp, includingTempoSteps: true))
        XCTAssertEqual(group.entries.map(\.quarter), [0, 0.5, 4.5])
        XCTAssertEqual(group.bpm(atQuarter: 4), 84)
        XCTAssertEqual(group.bpm(atQuarter: 4.5), 100)
        let last = try XCTUnwrap(group.entries.last)
        let toEnd = try map(group.deleting(last, includingTempoSteps: false))
        XCTAssertEqual(toEnd.bpm(atQuarter: 15), 84)

        // A local mark at the same beat as a score event must delete cleanly.
        let overlay = try map(.init(marks: [.init(quarter: 1, bpm: 150)]))
        let local = try XCTUnwrap(overlay.entries.first { $0.source == .practice })
        let removed = try map(overlay.deleting(local, includingTempoSteps: false))
        XCTAssertTrue(removed.marks.isEmpty)
        XCTAssertEqual(removed.bpm(atQuarter: 1), 120)
        XCTAssertEqual(removed.sourceRate(at: timing.performanceTime(scoreSeconds: midi.seconds(atQuarter: 1.1))),
                       120 / midi.tempo(atQuarter: 1), accuracy: 1e-8)
        XCTAssertEqual(removed.bpm(atQuarter: 2), midi.tempo(atQuarter: 2))
    }

    private func rampMIDI(finalTempo: Int = 600_000) -> Data {
        var track: [UInt8] = []
        for (i, us) in [500_000, 525_000, 550_000, 575_000, finalTempo].enumerated() {
            track += [i == 0 ? 0 : 2, 0xff, 0x51, 3, UInt8(us >> 16), UInt8((us >> 8) & 255), UInt8(us & 255)]
        }
        track += [24, 0xff, 0x2f, 0]
        return Data(Array("MThd".utf8) + [0,0,0,6,0,0,0,1,0,2] + Array("MTrk".utf8) + [0,0,0,UInt8(track.count)] + track)
    }

    @MainActor func testSaveReloadChangeStartAndRemovePracticeMark() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let midi = root.appendingPathComponent("practice.mid"), wav = root.appendingPathComponent("practice.wav")
        let data = rampMIDI()
        try data.write(to: midi)
        try Interpretation.encodeWAV(samples: Array(repeating: 0, count: 8000), sampleRate: 8000).write(to: wav)
        let model = PerformanceModel(defaults: defaults)
        model.outputMissing = true
        model.load(midi: midi, wav: wav)
        while model.state == .loading { await Task.yield() }
        let marks = [PracticeTempoMark(quarter: 4, bpm: 76)]
        try model.saveTempoMarks(marks)
        XCTAssertTrue(model.chooseStartMeasure("3"))
        while model.state == .loading { await Task.yield() }
        XCTAssertEqual(model.tempoEditorQuarter, 8)
        XCTAssertEqual(model.prepared?.practice.bpm(atQuarter: 8), 76)
        model.reload()
        while model.state == .loading { await Task.yield() }
        XCTAssertEqual(model.prepared?.practice.marks, marks)
        XCTAssertEqual(try Data(contentsOf: midi), data)
        let other = root.appendingPathComponent("other.mid")
        try rampMIDI(finalTempo: 650_000).write(to: other)
        model.load(midi: other, wav: wav)
        while model.state == .loading { await Task.yield() }
        XCTAssertEqual(model.prepared?.practice.marks, [])
        model.load(midi: midi, wav: wav)
        while model.state == .loading { await Task.yield() }
        XCTAssertThrowsError(try model.saveTempoMarks([.init(quarter: 4, bpm: -84)]))
        XCTAssertEqual(model.prepared?.practice.marks, marks)
        try model.saveTempoMarks([])
        model.reload()
        while model.state == .loading { await Task.yield() }
        XCTAssertEqual(model.prepared?.practice.bpm(atQuarter: 8), 100)
        let practice = try XCTUnwrap(model.prepared?.practice)
        let last = try XCTUnwrap(practice.entries.last)
        try model.saveTempoEdits(practice.deleting(last, includingTempoSteps: false))
        XCTAssertTrue(model.chooseStartMeasure("3"))
        while model.state == .loading { await Task.yield() }
        XCTAssertEqual(model.prepared?.practice.deleted, [4])
        model.reload()
        while model.state == .loading { await Task.yield() }
        XCTAssertEqual(model.prepared?.practice.deleted, [4])
        XCTAssertEqual(model.prepared?.practice.bpm(atQuarter: 8), practice.bpm(atQuarter: 3))
        XCTAssertEqual(try Data(contentsOf: midi), data)
        // Existing preferences were a flat array before score entries could be deleted.
        defaults.set(try JSONEncoder().encode(marks), forKey: "practice-tempos-" + model.fingerprint)
        model.reload()
        while model.state == .loading { await Task.yield() }
        XCTAssertEqual(model.prepared?.practice.marks, marks)
        XCTAssertEqual(model.prepared?.practice.deleted, [])

    }

    @MainActor func testFixedPlaybackUsesPracticeRateThroughRestartAndNextMarkOnThisMac() async throws {
        guard ProcessInfo.processInfo.environment["VC_DEVICE_CHECK"] == "1" else {
            throw XCTSkip("Set VC_DEVICE_CHECK=1 to check fixed playback with silent audio.")
        }
        let base = try FollowingFixture.prepared(), model = PerformanceModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let marks = [PracticeTempoMark(quarter: 0, bpm: 90), PracticeTempoMark(quarter: 0.5, bpm: 108)]
        let prepared = try PreparedPerformance(midi: base.midi, source: base.source, preparation: 0, passages: [], tempoMarks: marks)
        model.prepared = prepared; model.volume = 0
        let output = try XCTUnwrap(model.devices.first { $0.output && $0.id == AudioDevices.defaultID(input: false) })
        try model.audio.configure(device: output, format: base.source.format)
        defer { model.reset(); model.audio.shutdown() }
        for _ in 0..<2 {
            model.reset(); model.toggle()
            while model.state == .starting { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(model.state, .running)
            XCTAssertEqual(model.audio.playbackRate, 0.75)
            for _ in 0..<160 {
                if model.audio.playbackRate > 0.8 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(model.audio.playbackRate, 0.9, accuracy: 0.0001)
            XCTAssertEqual(model.elapsed(), model.audio.position(), accuracy: 0.003)
            model.pause()
            XCTAssertEqual(model.state, .paused)
        }
    }

    @MainActor func testTimePitchCanCombinePracticeTempoWithFollowingTolerance() {
        let audio = PerformanceAudio()
        for combinedRate in [0.25 * 0.7, 4 * 1.3] {
            audio.setRate(combinedRate)
            XCTAssertEqual(audio.playbackRate, combinedRate, accuracy: 1e-8)
        }
    }

    @MainActor func testFollowingRestartsAtMarkedPaceAndAdaptsAroundThatBaseline() async throws {
        let base = try FollowingFixture.prepared(), input = FollowingTestInput(), audio = FollowingTestAudio()
        let prepared = try PreparedPerformance(midi: base.midi, source: base.source, preparation: 0, passages: [],
            startMeasure: 2, tempoMarks: [.init(quarter: 0, bpm: 90), .init(quarter: 10, bpm: 120)])
        let plan = try FollowingPlan(score: FollowingFixture.score(silentMeasures: 0), solo: FollowingFixture.solo, waits: [], cadenzas: [])
        let diagnostics = FollowingDiagnostics(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var now = 0.0
        let following = LiveFollowing(diagnostics: diagnostics, capture: input, clock: { now }, permission: { true }, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        defer { following.stop(); try? FileManager.default.removeItem(at: diagnostics.root) }
        following.tolerance = 30
        for _ in 0..<2 {
            try await following.start(prepared: prepared, plan: plan, audio: audio, position: 0)
            XCTAssertEqual(audio.rates.last, 0.75)
            let began = now
            for _ in 0..<480 {
                now += 0.01
                audio.sourcePosition += 0.01 * (audio.rates.last ?? 1)
                let quarter = (now - began - 2.0/3.0) * 1.4
                let index = max(0, Int(floor(quarter)))
                following.observe(pitch: quarter < 0 ? nil : [60,62,64,65][index % 4], time: now)
                following.tick()
            }
            XCTAssertEqual(try XCTUnwrap(following.lastFollowedBPM), 84, accuracy: 3)
            XCTAssertEqual(try XCTUnwrap(diagnostics.report?.controls?.last).plannedBPM, 90, accuracy: 1e-8)
            XCTAssertTrue(try XCTUnwrap(diagnostics.report).replay().isEmpty)
            audio.sourcePosition = prepared.timing.performanceTime(scoreSeconds: prepared.midi.seconds(atQuarter: 10.1))
            following.tick()
            XCTAssertEqual(try XCTUnwrap(diagnostics.report?.controls?.last).plannedBPM, 120)
            XCTAssertGreaterThan(try XCTUnwrap(audio.rates.last), 0.9)
            following.stop()
        }
    }
}
