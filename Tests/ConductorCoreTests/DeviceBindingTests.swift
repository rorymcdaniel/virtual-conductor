import XCTest
import AVFoundation
import ConductorCore
@testable import VirtualConductor

final class DeviceBindingTests: XCTestCase {
    @MainActor func testPausingCadenzaReleasePreservesPedalReturnOnThisMac() async throws {
        guard ProcessInfo.processInfo.environment["VC_DEVICE_CHECK"] == "1" else { throw XCTSkip("Set VC_DEVICE_CHECK=1 to verify cadenza transport using silent output.") }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PerformanceModel(defaults: defaults, takeLibrary: TakeLibrary(root: root))
        let base = try FollowingFixture.prepared()
        base.source.floatChannelData![0].initialize(repeating: 0.1, count: Int(base.source.frameLength))
        let prepared = try PreparedPerformance(midi: base.midi, source: base.source, preparation: 0,
            passages: [CadenzaPassage(startMeasure: 1, startBeat: 1.1, returnMeasure: 3, returnBeat: 1)])
        model.prepared = prepared; model.audio.volume = 0
        let output = try XCTUnwrap(model.devices.first { $0.id == AudioDevices.defaultID(input: false) && $0.output })
        try model.audio.configure(device: output, format: prepared.source.format)
        defer { model.reset(); model.audio.shutdown() }
        let nodes = model.audio.engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }
        for action in ["pause", "space", "suspend"] {
            model.reset(); model.toggle()
            for _ in 0..<60 {
                if model.state == .waiting { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(model.state, .waiting)
            XCTAssertTrue(nodes.contains { $0.isPlaying }, "The release is still playing at the boundary")
            let boundary = model.elapsed()
            switch action {
            case "pause": model.pause()
            case "space": model.toggle()
            default: model.suspend("Application hidden.")
            }
            XCTAssertFalse(nodes.contains { $0.isPlaying }, "\(action) must silence the release")
            XCTAssertEqual(model.state, .waiting)
            XCTAssertEqual(model.elapsed(), boundary)
            model.cue()
            XCTAssertEqual(model.state, .running)
            XCTAssertEqual(model.elapsed(), prepared.segments[1].position, accuracy: 0.05)
        }
    }

    @MainActor func testIndependentInputAndOutputBindingsOnThisMac() async throws {
        guard ProcessInfo.processInfo.environment["VC_DEVICE_CHECK"] == "1" else { throw XCTSkip("Set VC_DEVICE_CHECK=1 for app-local device binding verification; no microphone samples captured.") }
        guard AVCaptureDevice.authorizationStatus(for:.audio) == .authorized else { throw XCTSkip("Microphone authorization must already be granted to the test host; use the signed app for permission and active capture checks.") }
        let devices = try AudioDevices.list()
        let output = try XCTUnwrap(devices.first { $0.id == AudioDevices.defaultID(input:false) && $0.output })
        let input = try XCTUnwrap(devices.first { $0.id == AudioDevices.defaultID(input:true) && $0.input })
        let audio = PerformanceAudio(); audio.volume = 0
        try audio.configure(device:output,format:AVAudioFormat(standardFormatWithSampleRate:44100,channels:2)!)
        defer { audio.shutdown() }
        let capture = InputCapture()
        var interrupted = false
        audio.interrupted = { interrupted = true }
        capture.interrupted = { [weak capture] in
            XCTFail("The selected microphone was interrupted during startup")
            capture?.release()
        }
        defer { capture.release() }
        // Some USB microphones post their startup notification only on a
        // subsequent Start. Exercise the same release/rebind cycle as Reset.
        for _ in 0..<3 {
            try await capture.startStreaming(device:input.id)
            try await Task.sleep(for:.milliseconds(750))
            XCTAssertTrue(capture.ready)
            XCTAssertGreaterThan(capture.storage?.receivedFrames.load(ordering:.acquiring) ?? 0,0)
            XCTAssertEqual(capture.storage?.count.load(ordering:.acquiring),0)
            capture.release()
        }
        XCTAssertFalse(interrupted)
        XCTAssertEqual(AudioDevices.boundID(audio.engine.outputNode),output.id)
        XCTAssertTrue(audio.ready)
        print("App-local output: \(output.name) [\(output.id)]; separate input: \(input.name) [\(input.id)]. Three successful microphone starts with recording disabled; no microphone samples retained.")
    }
}
