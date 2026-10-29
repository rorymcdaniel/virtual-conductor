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
        try capture.enable(device:input.id)
        defer { capture.release() }
        // Meter briefly with capture recording disabled; retain no microphone samples.
        try await Task.sleep(for:.milliseconds(500))
        XCTAssertTrue(capture.ready)
        XCTAssertGreaterThan(capture.storage?.receivedFrames.load(ordering:.acquiring) ?? 0,0)
        XCTAssertEqual(capture.storage?.count.load(ordering:.acquiring),0)
        XCTAssertFalse(interrupted)
        XCTAssertEqual(AudioDevices.boundID(audio.engine.outputNode),output.id)
        XCTAssertTrue(audio.ready)
        print("App-local output: \(output.name) [\(output.id)]; separate input: \(input.name) [\(input.id)]. Input engine active for 500 ms with recording disabled; no microphone samples retained.")
    }
}
