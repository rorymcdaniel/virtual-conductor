import XCTest
import AVFoundation
import ConductorCore
@testable import VirtualConductor

final class AudioContractTests: XCTestCase {
    private func midi() throws -> MIDIFile { try MIDIFile(data:Data(contentsOf:Bundle.module.url(forResource:"fractional-tempo",withExtension:"mid",subdirectory:"Fixtures")!)) }
    func testPreparedCutoffsReturnsClicksAndReleaseTail() throws {
        let midi = try midi(), rate = 8000.0
        let format = AVAudioFormat(standardFormatWithSampleRate:rate,channels:2)!
        let source = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:UInt32((midi.duration+1)*rate))!
        source.frameLength = source.frameCapacity
        for c in 0..<2 { for i in 0..<Int(source.frameLength) { source.floatChannelData![c][i] = Float(i%997)/1000 } }
        let passage = CadenzaPassage(startMeasure:1,startBeat:2,returnMeasure:1,returnBeat:4)
        let p = try PreparedPerformance(midi:midi,source:source,preparation:0,passages:[passage])
        XCTAssertEqual(p.segments.count,2)
        let first = p.segments[0], second = p.segments[1]
        XCTAssertEqual(first.end,p.timing.prepSeconds+midi.seconds(atQuarter:1))
        XCTAssertEqual(second.position,p.timing.prepSeconds+midi.seconds(atQuarter:3))
        XCTAssertEqual(Int(first.music.frameLength),Int((first.end*rate).rounded()))
        XCTAssertEqual(first.music.frameLength,first.clicks.frameLength)
        XCTAssertEqual(second.music.frameLength,second.clicks.frameLength)
        let sourceOffset = Int((second.position*rate).rounded())-Int((p.timing.prepSeconds*rate).rounded())
        XCTAssertEqual(second.music.floatChannelData![1][0],source.floatChannelData![1][sourceOffset])
        XCTAssertEqual(p.end,p.timing.prepSeconds+Double(source.frameLength)/rate)
        XCTAssertTrue(p.timing.position(p.end).ended)
        let prepFrames = Int((p.timing.prepSeconds*rate).rounded())
        XCTAssertTrue((0..<prepFrames).allSatisfy { first.music.floatChannelData![0][$0] == 0 })
        // Excluded boundary has no click: click buffers end exactly at the cutoff.
        XCTAssertTrue((max(0,Int(first.clicks.frameLength)-40)..<Int(first.clicks.frameLength)).allSatisfy { first.clicks.floatChannelData![0][$0] == 0 })
        let tailStart = Int(((p.timing.musicalEnd-second.position)*rate).rounded())
        XCTAssertTrue((tailStart..<Int(second.clicks.frameLength)).allSatisfy { second.clicks.floatChannelData![0][$0] == 0 })
    }
    func testCaptureStorageMonoLeadingSilenceAndLimit() {
        let rate = 100.0, storage = CaptureStorage(rate:rate)
        let format = AVAudioFormat(standardFormatWithSampleRate:rate,channels:2)!
        let block = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:128)!; block.frameLength = 128
        for i in 0..<128 { block.floatChannelData![0][i] = i < 10 ? 0 : 0.6; block.floatChannelData![1][i] = i < 10 ? 0 : 0.2 }
        storage.receive(AVReadOnlyAudioPCMBuffer(copying: block)); XCTAssertEqual(storage.count.load(ordering:.acquiring),0)
        storage.recording.store(true,ordering:.releasing)
        storage.receive(AVReadOnlyAudioPCMBuffer(copying: block))
        XCTAssertEqual(storage.count.load(ordering:.acquiring),128)
        XCTAssertEqual(storage.samples[0],0); XCTAssertEqual(storage.samples[10],0.4,accuracy:1e-6)
        for _ in 0..<100 { storage.receive(AVReadOnlyAudioPCMBuffer(copying: block)) }
        XCTAssertEqual(storage.count.load(ordering:.acquiring),12000)
    }
    @MainActor func testUtilitySuspensionClosesSheetAndCancelsStartingState() {
        let model = PerformanceModel()
        model.state = .starting
        model.openRecording()
        XCTAssertEqual(model.state,.paused)
        XCTAssertTrue(model.utilityOpen)
        model.suspend("Display unavailable.")
        XCTAssertFalse(model.utilityOpen)
        XCTAssertFalse(model.recording.inputReady)
    }
    @MainActor func testApprovalRevocationAndFailedCaptureRetainsPriorTake() throws {
        let midi = try midi(), model = RecordingModel(audio:PerformanceAudio())
        model.setScore(midi,fingerprint:"a"); model.open()
        model.take = RecordedTake(samples:[Float](repeating:0.2,count:8000),sampleRate:8000,range:PassageRange(start:0,end:4))
        model.manualStart = 0; model.manualEnd = 1; model.manual(); model.approve()
        XCTAssertTrue(model.approved)
        model.recording = true; model.captureInterrupted()
        XCTAssertEqual(model.take?.samples.count,8000); XCTAssertTrue(model.approved)
        model.editBeat(index:1,time:0.2); XCTAssertFalse(model.approved)
        model.approve(); XCTAssertTrue(model.approved)
        model.editBeat(index:1,time:-1); model.approve(); XCTAssertFalse(model.approved)
        model.setScore(midi,fingerprint:"b"); XCTAssertNil(model.take); XCTAssertTrue(model.beats.isEmpty)
    }
}
