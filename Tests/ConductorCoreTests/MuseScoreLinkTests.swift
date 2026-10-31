import XCTest
import ConductorCore
@testable import VirtualConductor

@MainActor final class MuseScoreLinkTests: XCTestCase {
    private func midi() throws -> MIDIFile {
        try MIDIFile(data: Data(contentsOf: Bundle.module.url(forResource: "fractional-tempo", withExtension: "mid", subdirectory: "Fixtures")!))
    }
    func testTempoRequestUsesBeatDistanceAndRestoresOriginalTempo() throws {
        let score = try midi()
        let range = PassageRange(start: 0, end: 2)
        let beats = [BeatTime(quarter: 0, time: 0), BeatTime(quarter: 1, time: 1), BeatTime(quarter: 2, time: 1.5)]
        let points = try MuseScoreLink.points(beats: beats, range: range, midi: score, duration: 2)
        XCTAssertEqual(points[0], TempoPoint(quarter: 0, bpm: 60))
        XCTAssertEqual(points[1], TempoPoint(quarter: 1, bpm: 120))
        XCTAssertEqual(points.last?.quarter, 2)
        XCTAssertEqual(points.last!.bpm, score.tempo(atSeconds: score.seconds(atQuarter: 2)))
    }
    func testRejectsTimingForAnotherPassage() throws {
        XCTAssertThrowsError(try MuseScoreLink.points(beats: [BeatTime(quarter: 0,time: 0), BeatTime(quarter: 1,time: 1)], range: PassageRange(start: 1,end: 2), midi: midi(), duration: 2))
    }
    func testLinkedRefreshRetainsRecordingAndTiming() throws {
        let model = RecordingModel(audio: PerformanceAudio())
        let score = try midi()
        model.setScore(score, fingerprint: "before")
        model.take = RecordedTake(samples: [0.1,0.2], sampleRate: 2, range: PassageRange(start: 0,end: 1))
        model.beats = [BeatTime(quarter: 0,time: 0),BeatTime(quarter: 1,time: 1)]
        model.trackIndex = 0
        model.refreshLinkedScore(score, fingerprint: "after")
        XCTAssertEqual(model.take?.samples,[0.1,0.2]); XCTAssertEqual(model.beats.count,2); XCTAssertEqual(model.trackIndex,0)
    }
    func testPrepareExportsMusicXMLFromSameSnapshotWithoutChangingSource() async throws {
        let fixture = try MuseScoreExportFixture()
        defer { fixture.close() }
        fixture.start()
        let files = try await fixture.link.prepare()
        XCTAssertEqual(files.musicXML.pathExtension, "musicxml")
        XCTAssertEqual(try String(contentsOf: files.musicXML, encoding: .utf8), fixture.originalXML)
        XCTAssertEqual(try fixture.exportInputs(), [files.score.path, files.score.path, files.score.path])
        XCTAssertEqual(files.musicXML.deletingPathExtension(), files.score.deletingPathExtension())
        XCTAssertEqual(fixture.link.rehearsal?.musicXML, files.musicXML)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceData)
        XCTAssertFalse(fixture.link.busy)
    }
    func testInvalidMusicXMLRetainsPreviousRehearsalAndReportsExportPaths() async throws {
        let fixture = try MuseScoreExportFixture()
        defer { fixture.close() }
        fixture.start()
        let previous = try await fixture.link.prepare()
        let originalMIDI = try Data(contentsOf: previous.midi)
        let originalWAV = try Data(contentsOf: previous.wav)
        for mode in ["missing", "empty", "malformed", "unreadable", "failed"] {
            try fixture.setXMLMode(mode)
            do {
                _ = try await fixture.link.prepare()
                XCTFail("Published \(mode) MusicXML")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("musicxml.log"), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains(fixture.link.root.path), error.localizedDescription)
            }
            XCTAssertEqual(fixture.link.rehearsal?.score, previous.score, mode)
            XCTAssertEqual(fixture.link.rehearsal?.musicXML, previous.musicXML, mode)
            XCTAssertEqual(try Data(contentsOf: previous.midi), originalMIDI)
            XCTAssertEqual(try Data(contentsOf: previous.wav), originalWAV)
            XCTAssertEqual(try String(contentsOf: previous.musicXML, encoding: .utf8), fixture.originalXML)
            XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceData)
            XCTAssertFalse(fixture.link.busy)
        }
    }
    func testKeepAdoptsChangedPreviewMusicXMLWithItsMIDIAndWAV() async throws {
        let fixture = try MuseScoreExportFixture()
        defer { fixture.close() }
        fixture.start()
        let prepared = try await fixture.link.prepare()
        let preview = try await fixture.makePreview()
        XCTAssertNotEqual(preview.musicXML, prepared.musicXML)
        XCTAssertEqual(try String(contentsOf: preview.musicXML, encoding: .utf8), fixture.previewXML)
        XCTAssertEqual(try MIDIFile(data: Data(contentsOf: prepared.midi)).openingBPM, 120)
        XCTAssertEqual(try MIDIFile(data: Data(contentsOf: preview.midi)).openingBPM, 60)
        let cached = try await fixture.makePreview()
        XCTAssertEqual(cached.musicXML, preview.musicXML)
        XCTAssertEqual(try fixture.exportInputs(), Array(repeating: prepared.score.path, count: 3) + Array(repeating: preview.score.path, count: 3))
        let kept = try await fixture.link.keep()
        XCTAssertEqual(kept.score, preview.score)
        XCTAssertEqual(kept.midi, preview.midi)
        XCTAssertEqual(kept.wav, preview.wav)
        XCTAssertEqual(kept.musicXML, preview.musicXML)
        XCTAssertEqual(fixture.link.rehearsal?.musicXML, preview.musicXML)
        XCTAssertNil(fixture.link.preview)
        XCTAssertEqual(fixture.requests.last?["revision"] as? String, "prepared-revision")
        XCTAssertEqual(fixture.requests.last?["operation"] as? String, "keep")
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceData)
    }
    func testFailedPreviewCannotBeKeptAndRetainsPreparedBundle() async throws {
        let fixture = try MuseScoreExportFixture()
        defer { fixture.close() }
        fixture.start()
        let prepared = try await fixture.link.prepare()
        try fixture.setXMLMode("malformed")
        do {
            _ = try await fixture.makePreview()
            XCTFail("Published malformed preview")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("preview.musicxml"))
            XCTAssertTrue(error.localizedDescription.contains("musicxml.log"))
        }
        XCTAssertNil(fixture.link.preview)
        XCTAssertEqual(fixture.link.rehearsal?.musicXML, prepared.musicXML)
        do {
            _ = try await fixture.link.keep()
            XCTFail("Kept failed preview")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Hear the accompaniment before keeping it.")
        }
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceData)
        XCTAssertFalse(fixture.link.busy)
    }
    func testChangedSourceSignatureDoesNotExportOrReplaceRehearsal() async throws {
        let fixture = try MuseScoreExportFixture()
        defer { fixture.close() }
        fixture.start()
        let prepared = try await fixture.link.prepare()
        fixture.snapshotRevision = "different-open-score"
        do {
            _ = try await fixture.link.prepare()
            XCTFail("Accepted mismatched saved score")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("saved file differs from the open score"))
        }
        XCTAssertEqual(try fixture.exportInputs().count, 3)
        XCTAssertEqual(fixture.link.rehearsal?.musicXML, prepared.musicXML)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceData)
        XCTAssertFalse(fixture.link.busy)
    }
    func testRejectedKeepRetainsPreparedAndPreviewBundlesWithoutRetry() async throws {
        let fixture = try MuseScoreExportFixture()
        defer { fixture.close() }
        fixture.start()
        let prepared = try await fixture.link.prepare()
        let preview = try await fixture.makePreview()
        fixture.keepError = "The score changed. Prepare again."
        do {
            _ = try await fixture.link.keep()
            XCTFail("Adopted rejected Keep")
        } catch {
            XCTAssertEqual(error.localizedDescription, fixture.keepError)
        }
        XCTAssertEqual(fixture.link.rehearsal?.musicXML, prepared.musicXML)
        XCTAssertEqual(fixture.link.preview?.musicXML, preview.musicXML)
        XCTAssertEqual(fixture.requests.filter { $0["operation"] as? String == "keep" }.count, 1)
        XCTAssertEqual(fixture.requests.last?["revision"] as? String, "prepared-revision")
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceData)
        XCTAssertFalse(fixture.link.busy)
    }
}
