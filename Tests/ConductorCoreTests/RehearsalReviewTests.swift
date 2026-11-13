import XCTest
import ConductorCore
@testable import VirtualConductor

final class TakeReviewTests: XCTestCase {
    func testClicksFollowAbsoluteBeatTimesAndDoNotModifyOriginal() throws {
        let rate = 8000.0, source = [Float](repeating: 0, count: 8000)
        let beats = [BeatTime(quarter: 0, time: 0.123), BeatTime(quarter: 1, time: 0.456), BeatTime(quarter: 2, time: 1)]
        let mixed = try TakeReviewAudio.render(samples: source, sampleRate: rate, beats: beats, clickLevel: 0.5)
        XCTAssertEqual(source, [Float](repeating: 0, count: 8000))
        XCTAssertGreaterThan(mixed.count, source.count, "Final boundary click must be audible")
        for beat in beats {
            let frame = Int((beat.time * rate).rounded())
            XCTAssertTrue(mixed[max(0, frame-10)..<frame].allSatisfy { $0 == 0 })
            XCTAssertGreaterThan(mixed[(frame+1)..<(frame+100)].map(abs).max()!, 0.01)
        }
        XCTAssertNotEqual(Array(mixed[985..<1025]), Array(mixed[3649..<3689]), "Downbeats have a distinct click")
        XCTAssertEqual(try TakeReviewAudio.render(samples: source, sampleRate: rate, beats: beats, clickLevel: 0), source)
        let loud = try TakeReviewAudio.render(samples: [Float](repeating: 1, count: 8000), sampleRate: rate, beats: beats, clickLevel: 1)
        XCTAssertLessThanOrEqual(loud.map(abs).max()!, 0.98001)
    }
    func testOriginsDistinguishAttacksHeldBeatsAndRelease() throws {
        let reference = [MIDINote(pitch: 60, startQuarter: 0, endQuarter: 2), MIDINote(pitch: 62, startQuarter: 2, endQuarter: 3), MIDINote(pitch: 64, startQuarter: 3, endQuarter: 4)]
        let observed = [ObservedNote(pitch: 60, start: 0, end: 1), ObservedNote(pitch: 62, start: 1, end: 1.5), ObservedNote(pitch: 64, start: 1.5, end: 2)]
        let result = try Interpretation.align(observed: observed, reference: reference, range: PassageRange(start: 0, end: 4), duration: 2)
        XCTAssertEqual(result.origins, [.attack, .inferred, .attack, .attack, .release])
    }
}

@MainActor final class TakePersistenceTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    func testNewTakesEditsRelaunchAndScoreIsolation() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let library = TakeLibrary(root: directory), score = try FollowingFixture.midi()
        var next: [Float] = [0.1, -0.3, 0.8]
        let model = RecordingModel(audio: PerformanceAudio(), library: library, copySamples: { _ in next })
        model.setScore(score, fingerprint: "A")
        model.finalizeCapture(CaptureStorage(rate: 3), rate: 3, range: PassageRange(start: 0, end: 4))
        while model.busy { await Task.yield() }
        let first = try XCTUnwrap(model.selectedTakeID)
        model.manualEnd = 1; model.manual(); model.editBeat(index: 1, time: 0.2); model.approve()
        XCTAssertFalse(model.saveFailed)
        next = [0.2, 0.4, 0.6]
        model.finalizeCapture(CaptureStorage(rate: 3), rate: 3, range: PassageRange(start: 0, end: 4))
        while model.busy { await Task.yield() }
        XCTAssertEqual(model.savedTakes.count, 2)
        let reopened = RecordingModel(audio: PerformanceAudio(), library: library)
        reopened.setScore(score, fingerprint: "A")
        XCTAssertEqual(reopened.take?.samples, next)
        reopened.restoreTake(first)
        XCTAssertEqual(reopened.take?.samples, [0.1, -0.3, 0.8])
        XCTAssertEqual(reopened.beats[1].time, 0.2); XCTAssertEqual(reopened.origins[1], .manual)
        XCTAssertTrue(reopened.approved); XCTAssertFalse(reopened.heardPreview)
        reopened.setScore(score, fingerprint: "B")
        XCTAssertNil(reopened.take); XCTAssertTrue(reopened.savedTakes.isEmpty)
        reopened.setScore(score, fingerprint: "A")
        XCTAssertEqual(reopened.savedTakes.count, 2)
    }
    func testFailedSaveKeepsTakeAndCanRetry() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: directory)
        let model = RecordingModel(audio: PerformanceAudio(), library: TakeLibrary(root: directory), copySamples: { _ in [0.5,0.25] })
        model.setScore(try FollowingFixture.midi(), fingerprint: "A")
        model.finalizeCapture(CaptureStorage(rate: 2), rate: 2, range: PassageRange(start: 0, end: 4))
        while model.busy { await Task.yield() }
        XCTAssertEqual(model.take?.samples, [0.5,0.25]); XCTAssertTrue(model.saveFailed)
        try FileManager.default.removeItem(at: directory)
        model.persistDraft()
        XCTAssertFalse(model.saveFailed); XCTAssertEqual(model.savedTakes.count, 1)
    }
    func testLateFinalizationArchivesToOriginalScoreWithoutReplacingCurrentTake() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let library = TakeLibrary(root: directory)
        var continuation: CheckedContinuation<[Float], Never>?
        let model = RecordingModel(audio: PerformanceAudio(), library: library, copySamples: { _ in await withCheckedContinuation { continuation = $0 } })
        let score = try FollowingFixture.midi()
        model.setScore(score, fingerprint: "A")
        model.finalizeCapture(CaptureStorage(rate: 2), rate: 2, range: PassageRange(start: 0, end: 4))
        while continuation == nil { await Task.yield() }
        model.setScore(score, fingerprint: "B"); continuation?.resume(returning: [0.2,0.4])
        for _ in 0..<200 {
            if try library.list(score: "A").takes.count == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(try library.list(score: "A").takes.count, 1)
        XCTAssertNil(model.take)
        XCTAssertTrue(try library.list(score: "B").takes.isEmpty)
    }
    func testUnreadableMetadataAndTruncatedAudioDoNotDestroyOtherTakes() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let library = TakeLibrary(root: directory)
        let item = SavedTake(id: UUID(), created: Date(), score: "A", sampleRate: 2, sampleCount: 2, range: PassageRange(start: 0, end: 4), trackIndex: 0, beats: [], origins: [], approved: false, manualStart: 0, manualEnd: 1)
        try library.save(item, samples: [0.1,0.2])
        let folder = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("broken".utf8).write(to: folder.appendingPathComponent("broken.json"))
        XCTAssertEqual(try library.list(score: "A").unreadable, 1)
        XCTAssertEqual(try library.load(item).samples, [0.1,0.2])
        try Data([1]).write(to: folder.appendingPathComponent(item.id.uuidString + ".pcm"))
        XCTAssertThrowsError(try library.load(item))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("broken.json").path))
    }
}

