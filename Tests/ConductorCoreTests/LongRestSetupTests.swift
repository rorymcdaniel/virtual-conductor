import XCTest
import AVFoundation
import ConductorCore
@testable import VirtualConductor

final class LongRestSetupTests: XCTestCase {
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
    private func loaded(_ name: String = "long-rest-eight-measures", identity: URL = URL(fileURLWithPath: "/score.mscz"), kept: Bool = false) throws -> LongRestSetup.Loaded {
        let url = fixture(name), score = try MusicXMLScore(data: Data(contentsOf: url))
        let midi = try MIDIFile(data: midiData(attacks: score.staves.flatMap(\.soundingIntervals).map(\.startQuarter), end: score.endQuarter))
        return LongRestSetup.Loaded(musicXML: url, identity: identity, midi: midi, keptTiming: kept)
    }
    func testOrdinaryGraceNoteDoesNotHideSoloStaff() throws {
        let original = try String(contentsOf: fixture("long-rest-eight-measures"), encoding: .utf8)
        let grace = "<note><grace slash=\"yes\"/><pitch><step>B</step><octave>4</octave></pitch><type>eighth</type></note>"
        let xml = original.replacingOccurrences(of: "<note><pitch><step>C", with: grace + "<note><pitch><step>C")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(xml.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let midi = try MIDIFile(data: midiData(attacks: [34.5], end: 36))
        let result = LongRestSetup.Loaded(musicXML: url, identity: url, midi: midi)
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
            try LongRestSetup.Loaded.validateMapping(score: score, midi: midi)
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
        var setup = LongRestSetup()
        let token = setup.beginLoading(); setup.finishLoading(try loaded("long-rest-voices-and-staves"), generation: token)
        XCTAssertNil(setup.selectedStaffID)
        XCTAssertGreaterThan(setup.staves.count, 1)
        let first = setup.staves[0].id, second = setup.staves[1].id
        setup.selectStaff(first); XCTAssertEqual(setup.schedule?.staffID, first)
        setup.selectStaff(second); XCTAssertEqual(setup.schedule?.staffID, second)
        setup.setThreshold(1); XCTAssertEqual(setup.schedule?.threshold, 1)
        setup.setThreshold(0); XCTAssertEqual(setup.threshold, 1)
        setup.setThreshold(-4); XCTAssertEqual(setup.threshold, 1)
        setup.selectStaff(MusicXMLStaffID(partID: "missing", staffNumber: 1)); XCTAssertNil(setup.schedule)
    }
    func testEightMeasureThresholdBoundaryAndNoAutomaticSelection() throws {
        var setup = LongRestSetup()
        let token = setup.beginLoading(); setup.finishLoading(try loaded(), generation: token)
        XCTAssertNil(setup.schedule)
        setup.selectStaff(setup.staves[0].id)
        XCTAssertEqual(setup.schedule?.runs.first?.fullMeasureCount, 8)
        setup.setThreshold(9); XCTAssertTrue(setup.schedule!.runs.isEmpty)
        setup.setThreshold(8); XCTAssertEqual(setup.schedule?.runs.count, 1)
    }
    func testReplacementClearsSameStaffIDAndStaleResultsCannotRestoreIt() throws {
        var setup = LongRestSetup()
        let first = setup.beginLoading(); setup.finishLoading(try loaded(), generation: first)
        setup.selectStaff(setup.staves[0].id)
        let stale = setup.beginLoading(), current = setup.beginLoading()
        XCTAssertNil(setup.schedule)
        setup.finishLoading(try loaded(identity: URL(fileURLWithPath: "/other.mscz")), generation: current)
        XCTAssertNil(setup.selectedStaffID)
        setup.finishLoading(try loaded(), generation: stale)
        XCTAssertNil(setup.selectedStaffID)
        setup.failLoading(generation: stale); XCTAssertFalse(setup.staves.isEmpty)
    }
    func testRereadAndKeptTimingRetainSelectionButBarePairClearsIt() throws {
        var setup = LongRestSetup()
        let first = setup.beginLoading(); setup.finishLoading(try loaded(), generation: first)
        let id = setup.staves[0].id; setup.selectStaff(id); setup.setThreshold(3)
        let reread = setup.beginLoading(); setup.finishLoading(try loaded(), generation: reread)
        XCTAssertEqual(setup.selectedStaffID, id)
        let keep = setup.beginLoading(); setup.finishLoading(try loaded(kept: true), generation: keep)
        XCTAssertEqual(setup.selectedStaffID, id); XCTAssertEqual(setup.threshold, 3)
        let midi = try MIDIFile(data: midiData(attacks: [34.5], end: 36))
        let bare = setup.beginLoading(); setup.finishLoading(.init(musicXML: nil, identity: nil, midi: midi), generation: bare)
        XCTAssertNil(setup.schedule); XCTAssertTrue(setup.staves.isEmpty)
        XCTAssertTrue(setup.availability.contains("matching MuseScore MusicXML"))
    }
    func testMappingRejectsLengthAndAttackMismatchAndAllowsTempoChanges() throws {
        let score = try MusicXMLScore(data: Data(contentsOf: fixture("long-rest-eight-measures")))
        XCTAssertThrowsError(try LongRestSetup.Loaded.validateMapping(score: score, midi: MIDIFile(data: midiData(attacks: [34.5], end: 40))))
        XCTAssertThrowsError(try LongRestSetup.Loaded.validateMapping(score: score, midi: MIDIFile(data: midiData(attacks: [33.5], end: 36))))
        XCTAssertNoThrow(try LongRestSetup.Loaded.validateMapping(score: score, midi: MIDIFile(data: midiData(attacks: [34.5], end: 36, tempo: 750_000))))
        XCTAssertNoThrow(try LongRestSetup.Loaded.validateMapping(score: score, midi: MIDIFile(data: midiData(attacks: [34.5], end: 35.95))))
        XCTAssertThrowsError(try LongRestSetup.Loaded.validateMapping(score: score, midi: MIDIFile(data: midiData(attacks: [30.5], end: 32))))
    }
    func testSustainingAccompanimentCannotSubstituteForMissingSoloAttack() throws {
        let original = try String(contentsOf: fixture("long-rest-eight-measures"), encoding: .utf8)
        let xml = original.replacingOccurrences(of: "<duration>5</duration></note>", with:
            "<duration>4</duration></note><note><pitch><step>G</step><octave>3</octave></pitch><duration>2</duration></note><backup><duration>1</duration></backup>")
        let score = try MusicXMLScore(data: Data(xml.utf8))
        // The accompaniment begins at 34 and spans the solo's missing 34.5 attack.
        let missing = try MIDIFile(data: midiData(attacks: [34], end: 36, noteTicks: 480))
        XCTAssertThrowsError(try LongRestSetup.Loaded.validateMapping(score: score, midi: missing))
        let matching = try MIDIFile(data: midiData(attacks: [34, 34.5], end: 36, noteTicks: 480))
        XCTAssertNoThrow(try LongRestSetup.Loaded.validateMapping(score: score, midi: matching))
    }

    func testChangedScoreAtSamePathClearsSelectionButKeptTempoRefreshPreservesIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let xml = directory.appendingPathComponent("score.musicxml")
        let original = try String(contentsOf: fixture("long-rest-eight-measures"), encoding: .utf8)
        try original.write(to: xml, atomically: true, encoding: .utf8)
        let midi = try MIDIFile(data: midiData(attacks: [34.5], end: 36))
        var setup = LongRestSetup()
        let first = setup.beginLoading()
        setup.finishLoading(.init(musicXML: xml, identity: xml, midi: midi), generation: first)
        let id = setup.staves[0].id; setup.selectStaff(id)
        let tempo = original.replacingOccurrences(of: "<measure number=\"2\">", with: "<measure number=\"2\"><direction><sound tempo=\"80\"/></direction>")
        try tempo.write(to: xml, atomically: true, encoding: .utf8)
        let keep = setup.beginLoading()
        setup.finishLoading(.init(musicXML: xml, identity: xml, midi: midi, keptTiming: true), generation: keep)
        XCTAssertEqual(setup.selectedStaffID, id)
        try tempo.replacingOccurrences(of: "<step>C</step>", with: "<step>D</step>").write(to: xml, atomically: true, encoding: .utf8)
        let replacement = setup.beginLoading()
        setup.finishLoading(.init(musicXML: xml, identity: xml, midi: midi), generation: replacement)
        XCTAssertNil(setup.selectedStaffID)
    }

    func testUnsupportedScoreIsNonfatalAndExplainsUnavailableCues() throws {
        let midi = try MIDIFile(data: midiData(attacks: [0], end: 4))
        let loaded = LongRestSetup.Loaded(musicXML: fixture("musicxml-pickup"), identity: nil, midi: midi)
        XCTAssertNil(loaded.score); XCTAssertTrue(loaded.unavailable!.contains("Pickup"))
    }

    @MainActor func testModelLoadsSidecarAndKeepRefreshThenBarePairClearsCues() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let midi = directory.appendingPathComponent("score.mid"), wav = directory.appendingPathComponent("score.wav")
        try midiData(attacks: [34.5], end: 36).write(to: midi)
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144000)!
        buffer.frameLength = buffer.frameCapacity
        try AVAudioFile(forWriting: wav, settings: format.settings).write(from: buffer)
        let model = PerformanceModel(); model.outputMissing = true
        model.load(midi: midi, wav: wav, musicXML: fixture("long-rest-eight-measures"), scoreIdentity: directory)
        while model.state == .loading { await Task.yield() }
        XCTAssertEqual(model.state, .ready)
        let id = try XCTUnwrap(model.longRestSetup.staves.first?.id)
        model.selectLongRestStaff(id)
        model.recording.onKeep?(RehearsalFiles(score: directory, midi: midi, wav: wav, musicXML: fixture("long-rest-eight-measures")))
        XCTAssertNil(model.longRestSetup.schedule)
        while model.state == .loading { await Task.yield() }
        XCTAssertEqual(model.longRestSetup.selectedStaffID, id)
        XCTAssertEqual(model.longRestSetup.schedule?.runs.first?.cue?.quarter, 34)
        model.load(midi: midi, wav: wav, musicXML: fixture("long-rest-eight-measures"), scoreIdentity: directory)
        model.load(midi: midi, wav: wav)
        while model.state == .loading { await Task.yield() }
        XCTAssertEqual(model.state, .ready); XCTAssertNil(model.longRestSetup.schedule)
    }
}
