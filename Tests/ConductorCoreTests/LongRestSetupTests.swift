import XCTest
import AVFoundation
import CryptoKit
import ConductorCore
@testable import VirtualConductor

final class LongRestSetupTests: XCTestCase {
    private let suite = "ScorePreparationTests." + UUID().uuidString
    private lazy var defaults = UserDefaults(suiteName: suite)!
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func fixture(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: "musicxml", subdirectory: "Fixtures")!
    }
    private func midiData(attacks: [Double], end: Double, tempo: Int = 500_000, noteTicks: Int = 1, pitches: [UInt8]? = nil) -> Data {
        func integer(_ value: Int, _ count: Int) -> [UInt8] {
            (0..<count).reversed().map { UInt8((value >> ($0 * 8)) & 255) }
        }
        func vlq(_ value: Int) -> [UInt8] {
            var value = value, bytes = [UInt8(value & 127)]
            value >>= 7
            while value > 0 { bytes.insert(UInt8(value & 127) | 128, at: 0); value >>= 7 }
            return bytes
        }
        var track: [UInt8] = [0,255,81,3] + integer(tempo,3)
        var events: [(Int,[UInt8])] = []
        for (index, attack) in attacks.enumerated() {
            let pitch = pitches?[index] ?? UInt8(24 + index % 80), tick = Int((attack * 480).rounded())
            events.append((tick,[144,pitch,80])); events.append((tick + noteTicks,[128,pitch,0]))
        }
        var tick = 0
        for event in events.sorted(by: { $0.0 < $1.0 }) {
            track += vlq(event.0 - tick) + event.1; tick = event.0
        }
        track += vlq(Int(end * 480) - tick) + [255,47,0]
        return Data(Array("MThd".utf8) + integer(6,4) + [0,0,0,1,1,224] + Array("MTrk".utf8) + integer(track.count,4) + track)
    }
    private func loaded(_ name: String = "long-rest-eight-measures", identity: URL = URL(fileURLWithPath: "/score.mscz"), kept: Bool = false) throws -> ScorePreparation.Loaded {
        let url = fixture(name), score = try MusicXMLScore(data: Data(contentsOf: url))
        let midi = try MIDIFile(data: midiData(attacks: score.staves.flatMap(\.soundingIntervals).map(\.startQuarter), end: score.endQuarter))
        return ScorePreparation.Loaded(musicXML: url, identity: identity, midi: midi, midiFingerprint: "test", keptTiming: kept)
    }
    func testOrdinaryGraceNoteDoesNotHideSoloStaff() throws {
        let original = try String(contentsOf: fixture("long-rest-eight-measures"), encoding: .utf8)
        let grace = "<note><grace slash=\"yes\"/><pitch><step>B</step><octave>4</octave></pitch><type>eighth</type></note>"
        let xml = original.replacingOccurrences(of: "<note><pitch><step>C", with: grace + "<note><pitch><step>C")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(xml.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let midi = try MIDIFile(data: midiData(attacks: [34.5], end: 36))
        let result = ScorePreparation.Loaded(musicXML: url, identity: url, midi: midi, midiFingerprint: "test")
        let score = try XCTUnwrap(result.score, result.unavailable ?? "")
        XCTAssertEqual(score.staves.first?.notes.map(\.startQuarter), [34.5])
    }
    func testGraceAndTremoloRenderingsKeepTheWrittenTimeline() throws {
        let xml = """
        <score-partwise><part id="Solo"><measure number="1">
        <attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>
        <note><rest/><duration>1</duration></note>
        <note><grace/><pitch><step>C</step><octave>4</octave></pitch><tie type="start"/></note>
        <note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration><tie type="stop"/></note>
        <note><pitch><step>F</step><octave>4</octave></pitch><duration>2</duration>
        <notations><ornaments><tremolo type="single">3</tremolo></ornaments></notations></note>
        <note><chord/><pitch><step>A</step><octave>4</octave></pitch><duration>2</duration></note>
        </measure></part></score-partwise>
        """
        let score = try MusicXMLScore(data: Data(xml.utf8))
        XCTAssertEqual(score.staves[0].notes.map(\.startQuarter), [1, 2, 2])
        let attacks = [0.875, 1, 1.125, 2, 2.25, 2.5]
        func validate(_ pitches: [UInt8]) throws {
            let midi = try MIDIFile(data: midiData(attacks: attacks, end: 4, pitches: pitches))
            try ScorePreparation.Loaded.validateMapping(score: score, midi: midi)
        }
        XCTAssertNoThrow(try validate([60, 60, 60, 65, 65, 69]))
        XCTAssertThrowsError(try validate([61, 60, 60, 65, 65, 69]))
        XCTAssertThrowsError(try validate([60, 60, 60, 65, 66, 69]))
    }

    func testTieContinuesWhenMuseScoreMovesThePitchToAnotherVoice() throws {
        let xml = """
        <score-partwise><part id="P"><measure number="1">
        <attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>
        <note><pitch><step>B</step><octave>2</octave></pitch><duration>4</duration><tie type="start"/><voice>2</voice></note>
        </measure><measure number="2">
        <note><pitch><step>B</step><octave>2</octave></pitch><duration>4</duration><tie type="stop"/><voice>1</voice></note>
        </measure></part></score-partwise>
        """
        let score = try MusicXMLScore(data: Data(xml.utf8))
        XCTAssertEqual(score.staves[0].notes, [MIDINote(pitch: 47, startQuarter: 0, endQuarter: 8)])
    }
    func testStaffAndThresholdRebuildOnlySelectedSchedule() throws {
        var score = ScorePreparation(defaults: defaults), rests = LongRestSetup()
        let token = score.beginLoading(); score.finishLoading(try loaded("long-rest-voices-and-staves"), generation: token)
        XCTAssertNil(score.selectedStaffID)
        XCTAssertGreaterThan(score.staves.count, 1)
        let first = score.staves[0].id, second = score.staves[1].id
        score.selectStaff(first); rests.update(from: score); XCTAssertEqual(rests.schedule?.staffID, first)
        score.selectStaff(second); rests.update(from: score); XCTAssertEqual(rests.schedule?.staffID, second)
        rests.setThreshold(1, preparation: score); XCTAssertEqual(rests.schedule?.threshold, 1)
        rests.setThreshold(0, preparation: score); XCTAssertEqual(rests.threshold, 1)
        rests.setThreshold(-4, preparation: score); XCTAssertEqual(rests.threshold, 1)
        score.selectStaff(MusicXMLStaffID(partID: "missing", staffNumber: 1)); rests.update(from: score)
        XCTAssertNil(score.selectedStaffID); XCTAssertNil(rests.schedule)
    }
    func testEightMeasureThresholdBoundaryAndNoAutomaticSelection() throws {
        var score = ScorePreparation(defaults: defaults), rests = LongRestSetup()
        let token = score.beginLoading(); score.finishLoading(try loaded(), generation: token)
        XCTAssertNil(score.selectedStaffID)
        score.selectStaff(score.staves[0].id); rests.update(from: score)
        XCTAssertEqual(rests.schedule?.runs.first?.fullMeasureCount, 8)
        rests.setThreshold(9, preparation: score); XCTAssertTrue(rests.schedule!.runs.isEmpty)
        rests.setThreshold(8, preparation: score); XCTAssertEqual(rests.schedule?.runs.count, 1)
    }
    func testReplacementClearsSameStaffIDAndStaleResultsCannotRestoreIt() throws {
        var setup = ScorePreparation(defaults: defaults)
        let first = setup.beginLoading(); setup.finishLoading(try loaded(), generation: first)
        setup.selectStaff(setup.staves[0].id)
        let stale = setup.beginLoading(), current = setup.beginLoading()
        XCTAssertNil(setup.score); XCTAssertNil(setup.selectedStaffID)
        setup.finishLoading(try loaded("long-rest-separated-runs", identity: URL(fileURLWithPath: "/other.mscz")), generation: current)
        XCTAssertNil(setup.selectedStaffID)
        setup.finishLoading(try loaded(), generation: stale)
        XCTAssertNil(setup.selectedStaffID)
        setup.failLoading(generation: stale); XCTAssertFalse(setup.staves.isEmpty)
    }
    func testRereadAndKeptTimingRetainSelectionButBarePairClearsIt() throws {
        var setup = ScorePreparation(defaults: defaults)
        let first = setup.beginLoading(); setup.finishLoading(try loaded(), generation: first)
        let id = setup.staves[0].id; setup.selectStaff(id)
        let reread = setup.beginLoading(); setup.finishLoading(try loaded(), generation: reread)
        XCTAssertEqual(setup.selectedStaffID, id)
        let keep = setup.beginLoading(); setup.finishLoading(try loaded(kept: true), generation: keep)
        XCTAssertEqual(setup.selectedStaffID, id)
        let midi = try MIDIFile(data: midiData(attacks: [34.5], end: 36))
        let bare = setup.beginLoading(); setup.finishLoading(.init(musicXML: nil, identity: nil, midi: midi, midiFingerprint: "test"), generation: bare)
        XCTAssertNil(setup.selectedStaffID); XCTAssertTrue(setup.staves.isEmpty)
        XCTAssertTrue(setup.unavailableReason?.contains("matching MuseScore MusicXML") == true)
    }
    func testMappingRejectsLengthAndAttackMismatchAndAllowsTempoChanges() throws {
        let score = try MusicXMLScore(data: Data(contentsOf: fixture("long-rest-eight-measures")))
        XCTAssertThrowsError(try ScorePreparation.Loaded.validateMapping(score: score, midi: MIDIFile(data: midiData(attacks: [34.5], end: 40))))
        XCTAssertThrowsError(try ScorePreparation.Loaded.validateMapping(score: score, midi: MIDIFile(data: midiData(attacks: [33.5], end: 36))))
        XCTAssertNoThrow(try ScorePreparation.Loaded.validateMapping(score: score, midi: MIDIFile(data: midiData(attacks: [34.5], end: 36, tempo: 750_000))))
        XCTAssertNoThrow(try ScorePreparation.Loaded.validateMapping(score: score, midi: MIDIFile(data: midiData(attacks: [34.5], end: 35.95))))
        XCTAssertThrowsError(try ScorePreparation.Loaded.validateMapping(score: score, midi: MIDIFile(data: midiData(attacks: [30.5], end: 32))))
    }
    func testSustainingAccompanimentCannotSubstituteForMissingSoloAttack() throws {
        let original = try String(contentsOf: fixture("long-rest-eight-measures"), encoding: .utf8)
        let xml = original.replacingOccurrences(of: "<duration>5</duration></note>", with:
            "<duration>4</duration></note><note><pitch><step>G</step><octave>3</octave></pitch><duration>2</duration></note><backup><duration>1</duration></backup>")
        let score = try MusicXMLScore(data: Data(xml.utf8))
        // The accompaniment begins at 34 and spans the solo's missing 34.5 attack.
        let missing = try MIDIFile(data: midiData(attacks: [34], end: 36, noteTicks: 480))
        XCTAssertThrowsError(try ScorePreparation.Loaded.validateMapping(score: score, midi: missing))
        let matching = try MIDIFile(data: midiData(attacks: [34, 34.5], end: 36, noteTicks: 480))
        XCTAssertNoThrow(try ScorePreparation.Loaded.validateMapping(score: score, midi: matching))
    }

    func testChangedScoreAtSamePathClearsSelectionButKeptTempoRefreshPreservesIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let xml = directory.appendingPathComponent("score.musicxml")
        let original = try String(contentsOf: fixture("long-rest-eight-measures"), encoding: .utf8)
        try original.write(to: xml, atomically: true, encoding: .utf8)
        let midi = try MIDIFile(data: midiData(attacks: [34.5], end: 36))
        var setup = ScorePreparation(defaults: defaults)
        let first = setup.beginLoading()
        setup.finishLoading(.init(musicXML: xml, identity: xml, midi: midi, midiFingerprint: "test"), generation: first)
        let id = setup.staves[0].id; setup.selectStaff(id)
        let tempo = original.replacingOccurrences(of: "<measure number=\"2\">", with: "<measure number=\"2\"><direction><sound tempo=\"80\"/></direction>")
        try tempo.write(to: xml, atomically: true, encoding: .utf8)
        let keep = setup.beginLoading()
        setup.finishLoading(.init(musicXML: xml, identity: xml, midi: midi, midiFingerprint: "test", keptTiming: true), generation: keep)
        XCTAssertEqual(setup.selectedStaffID, id)
        try tempo.replacingOccurrences(of: "<step>C</step>", with: "<step>D</step>").write(to: xml, atomically: true, encoding: .utf8)
        let replacement = setup.beginLoading()
        setup.finishLoading(.init(musicXML: xml, identity: xml, midi: midi, midiFingerprint: "test"), generation: replacement)
        XCTAssertNil(setup.selectedStaffID)
    }

    func testUnsupportedScoreIsNonfatalAndExplainsUnavailableCues() throws {
        let midi = try MIDIFile(data: midiData(attacks: [0], end: 4))
        let loaded = ScorePreparation.Loaded(musicXML: fixture("musicxml-pickup"), identity: nil, midi: midi, midiFingerprint: "test")
        XCTAssertNil(loaded.score); XCTAssertTrue(loaded.unavailable!.contains("Pickup"))
    }

    private func silentWAV(at url: URL, seconds: Int) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 8000))!
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }

    @MainActor func testLegacySettingsAndBothStaffPickersDriveTheSameScore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "ScorePreparationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let midi = directory.appendingPathComponent("score.mid"), wav = directory.appendingPathComponent("score.wav")
        let xml = fixture("musicxml-multi-staff")
        let data = midiData(attacks: [0, 0.5, 1, 4], end: 8)
        try data.write(to: midi)
        try silentWAV(at: wav, seconds: 4)
        func fingerprint(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let key = try "following-v1-" + fingerprint(data) + "-" + fingerprint(Data(contentsOf: xml))
        // Existing flat JSON, from before free passages were introduced.
        let legacy = #"{"enabled":true,"solo":{"partID":"Piano","staffNumber":2},"waits":[{"measure":1,"beat":1.5}]}"#
        defaults.set(Data(legacy.utf8), forKey: key)
        let model = PerformanceModel(defaults: defaults)
        model.outputMissing = true
        model.load(midi: midi, wav: wav, musicXML: xml)
        while model.state == .loading { await Task.yield() }
        XCTAssertEqual(model.state, .ready)
        let saved = MusicXMLStaffID(partID: "Piano", staffNumber: 2)
        let other = MusicXMLStaffID(partID: "Other", staffNumber: 1)
        XCTAssertTrue(model.scorePreparation.following.enabled)
        XCTAssertEqual(model.longRestSetup.schedule?.staffID, saved)
        XCTAssertEqual(try model.followingPlan().waits, [0.5])
        XCTAssertEqual(try model.followingPlan().notes.map(\.pitch), [48])

        var draft = model.scorePreparation.following
        draft.solo = other
        draft.waits = [WaitPoint(measure: 2, beat: 1)]
        XCTAssertThrowsError(try model.saveFollowing(draft, tolerance: .nan))
        XCTAssertEqual(model.longRestSetup.schedule?.staffID, saved)
        let microphone = AudioDevice(id: 701, uid: "test-usb-mic", name: "Test USB mic", input: true, output: false)
        model.devices = [microphone]
        try model.saveFollowing(draft, tolerance: 15, inputID: microphone.id)
        XCTAssertEqual(model.longRestSetup.schedule?.staffID, other)
        XCTAssertEqual(try model.followingPlan().waits, [4])
        XCTAssertEqual(try model.followingPlan().notes.map(\.pitch), [74])
        let stored = try JSONDecoder().decode(FollowingConfiguration.self, from: XCTUnwrap(defaults.data(forKey: key)))
        XCTAssertEqual(stored.solo, other)
        XCTAssertEqual(stored.waits, draft.waits)

        let relaunched = PerformanceModel(defaults: defaults)
        relaunched.outputMissing = true
        relaunched.restoreRehearsal()
        while relaunched.state == .loading { await Task.yield() }
        XCTAssertEqual(relaunched.state, .ready)
        XCTAssertEqual(relaunched.midiURL, midi.standardizedFileURL)
        XCTAssertEqual(relaunched.longRestSetup.schedule?.staffID, other)
        XCTAssertEqual(try relaunched.followingPlan().waits, [4])
        XCTAssertEqual(relaunched.following.tolerance, 15)
        XCTAssertEqual(relaunched.followingInputID(), 0) // A missing explicit input must not fall back to the system microphone.
        relaunched.devices = [AudioDevice(id: 702, uid: microphone.uid, name: microphone.name, input: true, output: false)]
        XCTAssertEqual(relaunched.followingInputID(), 702) // Core Audio can assign a new numeric ID after a restart.

        model.selectSoloStaff(saved)
        XCTAssertEqual(model.longRestSetup.schedule?.staffID, saved)
        XCTAssertThrowsError(try model.followingPlan()) // The old wait is not an attack on this staff.
        model.reload()
        while model.state == .loading { await Task.yield() }
        XCTAssertEqual(model.longRestSetup.schedule?.staffID, saved) // A reread keeps the current choice.

        let replacement = directory.appendingPathComponent("replacement.musicxml")
        try (String(contentsOf: xml, encoding: .utf8) + "\n<!-- new export -->").write(to: replacement, atomically: true, encoding: .utf8)
        model.load(midi: midi, wav: wav, musicXML: replacement)
        while model.state == .loading { await Task.yield() }
        XCTAssertNil(model.scorePreparation.selectedStaffID)
        XCTAssertNil(model.longRestSetup.schedule)
        XCTAssertFalse(model.scorePreparation.following.enabled)
        XCTAssertTrue(model.scorePreparation.following.waits.isEmpty)
        XCTAssertEqual(model.following.tolerance, 15)

        try midiData(attacks: [0, 1, 4], end: 8).write(to: midi)
        model.load(midi: midi, wav: wav, musicXML: xml)
        while model.state == .loading { await Task.yield() }
        XCTAssertEqual(model.state, .ready)
        XCTAssertNotNil(model.prepared)
        XCTAssertNil(model.longRestSetup.schedule)
        XCTAssertTrue(model.longRestSetup.availability.contains("matching linear timeline"))
        XCTAssertThrowsError(try model.followingPlan()) { error in
            XCTAssertTrue(error.localizedDescription.contains("matching linear timeline"))
        }
    }

    @MainActor func testModelLoadsSidecarAndKeepRefreshThenBarePairClearsCues() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let midi = directory.appendingPathComponent("score.mid"), wav = directory.appendingPathComponent("score.wav")
        try midiData(attacks: [34.5], end: 36).write(to: midi)
        try silentWAV(at: wav, seconds: 28)
        let suite = "ScorePreparationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CadenzaSettings(fileURL: directory.appendingPathComponent("cadenzas.json"))
        let model = PerformanceModel(defaults: defaults, cadenzaSettings: store); model.outputMissing = true
        let xml = fixture("long-rest-eight-measures")
        model.load(midi: midi, wav: wav, musicXML: xml, scoreIdentity: directory)
        while model.state == .loading { await Task.yield() }
        XCTAssertEqual(model.state, .ready)
        let id = try XCTUnwrap(model.scorePreparation.staves.first?.id)
        let cadenza = CadenzaPassage(startMeasure: 2, startBeat: 1, returnMeasure: 3, returnBeat: 1)
        try model.commitPassages([cadenza])
        while model.state == .loading { await Task.yield() }
        var draft = model.scorePreparation.following
        draft.solo = id; draft.enabled = true
        draft.waits = [WaitPoint(measure: 9, beat: 3.5)]
        try model.saveFollowing(draft, tolerance: 10)
        let take = RecordedTake(samples: [0, 0.5], sampleRate: 2, range: PassageRange(start: 32, end: 36))
        model.recording.take = take
        let keptMIDI = directory.appendingPathComponent("kept.mid"), keptXML = directory.appendingPathComponent("kept.musicxml")
        try midiData(attacks: [34.5], end: 36, tempo: 750_000).write(to: keptMIDI)
        let updated = try String(contentsOf: xml, encoding: .utf8)
            .replacingOccurrences(of: "<measure number=\"2\">", with: "<measure number=\"2\"><direction><sound tempo=\"80\"/></direction>")
        try updated.write(to: keptXML, atomically: true, encoding: .utf8)
        model.recording.onKeep?(RehearsalFiles(score: directory, midi: keptMIDI, wav: wav, musicXML: keptXML))
        XCTAssertNil(model.longRestSetup.schedule)
        while model.state == .loading { await Task.yield() }
        XCTAssertEqual(model.scorePreparation.selectedStaffID, id)
        XCTAssertEqual(model.longRestSetup.schedule?.runs.first?.cue?.quarter, 34)
        XCTAssertEqual(try model.followingPlan().notes.first?.startQuarter, 34.5)
        XCTAssertEqual(model.recording.take?.samples, take.samples)
        XCTAssertEqual(model.prepared?.midi.openingBPM, 80)
        XCTAssertFalse(model.scorePreparation.following.enabled)
        XCTAssertTrue(model.scorePreparation.following.waits.isEmpty)
        let relaunched = PerformanceModel(defaults: defaults, cadenzaSettings: store)
        relaunched.outputMissing = true
        relaunched.restoreRehearsal()
        while relaunched.state == .loading { await Task.yield() }
        XCTAssertEqual(relaunched.state, .ready)
        XCTAssertEqual(relaunched.midiURL, keptMIDI.standardizedFileURL)
        XCTAssertEqual(relaunched.longRestSetup.schedule?.staffID, id)
        XCTAssertEqual(relaunched.passages, [cadenza])
        model.load(midi: midi, wav: wav, musicXML: fixture("long-rest-eight-measures"), scoreIdentity: directory)
        model.load(midi: midi, wav: wav)
        while model.state == .loading { await Task.yield() }
        XCTAssertEqual(model.state, .ready); XCTAssertNil(model.longRestSetup.schedule)
        XCTAssertNil(model.scorePreparation.selectedStaffID)
        XCTAssertFalse(model.scorePreparation.following.enabled)
        XCTAssertThrowsError(try model.followingPlan()) { error in
            XCTAssertTrue(error.localizedDescription.contains("matching MuseScore MusicXML"))
        }
    }
}
