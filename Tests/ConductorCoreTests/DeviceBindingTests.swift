import XCTest
import AVFoundation
@testable import VirtualConductor

final class DeviceBindingTests: XCTestCase {
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
