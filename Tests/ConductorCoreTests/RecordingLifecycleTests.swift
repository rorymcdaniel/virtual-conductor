import XCTest
import ConductorCore
@testable import VirtualConductor

@MainActor final class RecordingLifecycleTests: XCTestCase {
    private func midi() throws -> MIDIFile { try MIDIFile(data:Data(contentsOf:Bundle.module.url(forResource:"fractional-tempo",withExtension:"mid",subdirectory:"Fixtures")!)) }
    func testPermissionAfterCloseCannotEnableInput() async {
        var continuation: CheckedContinuation<Bool,Never>?
        let model = RecordingModel(audio:PerformanceAudio(), permission: { await withCheckedContinuation { continuation = $0 } })
        model.open(); model.enableInput()
        while continuation == nil { await Task.yield() }
        model.close(); continuation?.resume(returning:true)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(model.inputReady); XCTAssertFalse(model.busy); XCTAssertFalse(model.recording)
    }
    func testCloseReopenKeepsFinalizationOwnershipAndRetainsTake() async throws {
        var continuation: CheckedContinuation<[Float],Never>?
        var permissionRequests = 0
        let model = RecordingModel(audio:PerformanceAudio(),permission:{ permissionRequests += 1; return false },copySamples:{ _ in await withCheckedContinuation { continuation = $0 } })
        model.setScore(try midi(),fingerprint:"A"); model.open()
        model.finalizeCapture(CaptureStorage(rate:100),rate:100,range:PassageRange(start:0,end:4))
        while continuation == nil { await Task.yield() }
        model.close(); model.open(); model.enableInput()
        XCTAssertTrue(model.busy); XCTAssertEqual(permissionRequests,0)
        continuation?.resume(returning:[0,0,0.5])
        while model.busy { await Task.yield() }
        XCTAssertEqual(model.take?.samples,[0,0,0.5]); XCTAssertFalse(model.approved)
    }
    func testScoreRoundTripCannotAcceptOldCaptureCompletion() async throws {
        var continuation: CheckedContinuation<[Float],Never>?
        let model = RecordingModel(audio:PerformanceAudio(),copySamples:{ _ in await withCheckedContinuation { continuation = $0 } })
        let score = try midi()
        model.setScore(score,fingerprint:"A")
        model.finalizeCapture(CaptureStorage(rate:100),rate:100,range:PassageRange(start:0,end:4))
        while continuation == nil { await Task.yield() }
        model.setScore(score,fingerprint:"B"); model.setScore(score,fingerprint:"A")
        continuation?.resume(returning:[0.5])
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(model.take); XCTAssertFalse(model.busy)
    }
}
