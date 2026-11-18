import XCTest
import AVFoundation
import Synchronization
@testable import VirtualConductor

/// Only synthesized audio from an explicitly selected loopback device is inspected.
private final class LoopbackTiming: Sendable {
    let frames = Atomic<Int>(0)
    let first = Atomic<Double>(0)
    let last = Atomic<Double>(0)
    func receive(_ buffer: AVReadOnlyAudioPCMBuffer, time: AVAudioTime) {
        frames.wrappingAdd(Int(buffer.frameLength), ordering: .relaxed)
        guard case .float(let channel) = buffer.channelData(0) else { return }
        let start = AVAudioTime.seconds(forHostTime: time.hostTime)
        for i in 0..<Int(buffer.frameLength) where abs(channel[i * buffer.stride]) > 0.002 {
            let seconds = start + Double(i)/buffer.format.sampleRate
            if first.load(ordering: .relaxed) == 0 { first.store(seconds, ordering: .releasing) }
            last.store(seconds, ordering: .releasing)
        }
    }
}

final class MultiOutputTimingTests: XCTestCase {
    @MainActor func testMultiOutputPlaybackTimingOnThisMac() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let outputName = env["VC_MULTI_OUTPUT_CHECK"], let inputName = env["VC_LOOPBACK_CHECK"] else {
            throw XCTSkip("Set VC_MULTI_OUTPUT_CHECK and VC_LOOPBACK_CHECK to check short, quiet synthesized tones.")
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("Loopback capture requires existing microphone authorization for the test host.")
        }
        let devices = try AudioDevices.list()
        let output = try XCTUnwrap(devices.first { $0.output && $0.name == outputName })
        let input = try XCTUnwrap(devices.first { $0.input && $0.name == inputName })
        let capture = AVAudioEngine(), observed = LoopbackTiming()
        try AudioDevices.bind(capture.inputNode, device: input.id)
        let inputFormat = capture.inputNode.outputFormat(forBus: 0)
        try capture.inputNode.installAudioTap(onBus: 0, bufferSize: 256, format: inputFormat) { buffer, time in
            observed.receive(buffer, time: time)
        }
        try capture.start()
        defer { capture.stop(); capture.inputNode.removeTap(onBus: 0) }
        let audio = PerformanceAudio(); audio.volume = 0.03
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        try audio.configure(device: output, format: format)
        defer { audio.shutdown() }
        // Device startup can stop the input engine while Core Audio settles.
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            if observed.frames.load(ordering: .acquiring) > 0 { break }
            if !capture.isRunning { try capture.start() }
        }
        XCTAssertGreaterThan(observed.frames.load(ordering: .acquiring), 0, "Loopback must be receiving before checking playback")
        let tone = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 13230)!
        tone.frameLength = tone.frameCapacity
        for i in 0..<Int(tone.frameLength) {
            let gain = min(1, Double(i)/441, Double(Int(tone.frameLength)-i)/441)
            let sample = Float(sin(2 * Double.pi * 440 * Double(i)/44100) * gain)
            for c in 0..<2 { tone.floatChannelData![c][i] = sample }
        }
        let clickFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let silence = AVAudioPCMBuffer(pcmFormat: clickFormat, frameCapacity: tone.frameLength)!
        silence.frameLength = tone.frameLength
        silence.floatChannelData![0].initialize(repeating: 0, count: Int(silence.frameLength))
        let segment = AudioSegment(position: 12, end: 12.3, music: tone, clicks: silence)
        for (immediate, rate) in [(false, 1.0), (true, 1.0), (false, 1.2), (false, 1.2), (true, 0.8), (false, 0.8)] {
            // Let the engine clock advance, including between player stop/restarts.
            try await Task.sleep(for: .milliseconds(250))
            observed.first.store(0, ordering: .releasing); observed.last.store(0, ordering: .releasing)
            audio.setRate(rate)
            try audio.play(segment, immediate: immediate)
            let expected = audio.audibleOrigin + segment.position
            try await Task.sleep(for: .milliseconds(850))
            let first = observed.first.load(ordering: .acquiring), last = observed.last.load(ordering: .acquiring)
            print("[route-timing] immediate=\(immediate) rate=\(rate) onsetError=\(first-expected) duration=\(last-first) captureFrames=\(observed.frames.load(ordering: .relaxed)) engineFrame=\(audio.engine.manualRenderingSampleTime)")
            XCTAssertGreaterThan(first, 0, "Both scheduled and immediate starts must render audio")
            XCTAssertEqual(first, expected, accuracy: 0.055, "Audible clock must match loopback onset")
            XCTAssertEqual(last-first, 0.3/rate, accuracy: 0.06, "Tempo changes must reach the output")
            XCTAssertTrue(audio.ready)
            audio.stop()
        }
        observed.first.store(0, ordering: .releasing); observed.last.store(0, ordering: .releasing)
        audio.setRate(1)
        let deferredBefore = audio.renderDelay
        try audio.play(segment, immediate: false)
        for _ in 0..<9 { audio.append(segment) }
        var predictedEnd = audio.audibleOrigin + segment.position + 3
        for i in 0..<210 {
            try await Task.sleep(for: .milliseconds(15))
            // Match the live controller cadence, including unchanged writes.
            let rate = i < 65 ? 1.0 : (i < 125 ? 1.2 : 0.8)
            audio.setRate(rate)
            let remaining = max(0, segment.position + 3 - audio.position())
            if remaining > 0 { predictedEnd = PerformanceAudio.hostSeconds + remaining/rate }
        }
        try await Task.sleep(for: .milliseconds(400))
        let last = observed.last.load(ordering: .acquiring)
        print("[route-timing] continuous tempo updates: deferredSeconds=\(audio.renderDelay-deferredBefore) endError=\(last-predictedEnd)")
        XCTAssertLessThan(audio.renderDelay-deferredBefore, 0.02, "Live rate updates must not repeatedly reject rendering")
        XCTAssertEqual(last, predictedEnd, accuracy: 0.06, "Live tempo changes and appended buffers must preserve the audible transport clock")
        XCTAssertTrue(audio.ready)
        audio.stop()
    }
}
