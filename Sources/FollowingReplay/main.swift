import Foundation
import AVFoundation
import ConductorCore

func analyzeAudio(_ url: URL, report: FollowingDiagnostic) throws -> [SoloObservation] {
    guard report.audioStart != nil else { throw MusicalError("This report contains no opted-in audio.") }
    let file = try AVAudioFile(forReading: url.deletingLastPathComponent().appendingPathComponent("audio.wav"))
    guard file.length > 0, file.length <= 384000 * 15,
          file.processingFormat.sampleRate == report.sampleRate,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw MusicalError("Invalid audio excerpt.") }
    try file.read(into: buffer)
    guard let data = buffer.floatChannelData else { throw MusicalError("Cannot decode excerpt.") }
    var analyzer = SoloAudioAnalyzer(sampleRate: file.processingFormat.sampleRate)
    return analyzer.process(Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))))
}

// No GUI, microphone, network, or writes. Replays a saved local report.
do {
    guard CommandLine.arguments.count >= 2 else { throw MusicalError("Usage: FollowingReplay /path/to/report.json [--audio], or FollowingReplay --cases /path/to/private-cases.json") }
    if CommandLine.arguments[1] == "--cases" {
        guard CommandLine.arguments.count == 3 else { throw MusicalError("Supply one rehearsal case manifest.") }
        let manifest = URL(fileURLWithPath: CommandLine.arguments[2])
        let cases = try JSONDecoder().decode([FollowingRehearsalCase].self, from: Data(contentsOf: manifest))
        guard !cases.isEmpty else { throw MusicalError("The rehearsal collection is empty.") }
        var failed = false
        for test in cases {
            let url = test.report.hasPrefix("/") ? URL(fileURLWithPath: test.report) : manifest.deletingLastPathComponent().appendingPathComponent(test.report)
            let report = try FollowingDiagnostic.decode(Data(contentsOf: url))
            let observations = test.source == "audio" ? try analyzeAudio(url, report: report) : nil
            let result = try FollowingRehearsal.run(test, report: report, audioObservations: observations)
            print(String(format: "%@: %@ (%@), %d frames, %d matches, %.3f–%.3fx planned tempo", result.passed ? "PASS" : "FAIL", test.name, test.source, result.frames, result.matches, result.minimumRate, result.maximumRate))
            failed = failed || !result.passed
        }
        print("Continuous recognition and simulated accompaniment control; excludes physical device latency and acoustic output.")
        exit(failed ? 2 : 0)
    }
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let report = try FollowingDiagnostic.decode(Data(contentsOf: url))
    let mismatches = report.replay()
    print("Replayed \(report.decisions.count) recognition decisions; \(mismatches.count) changed results.")
    let controlMismatches = report.replayControls()
    print("Replayed \(report.controls?.count ?? 0) playback commands; \(controlMismatches.count) changed results.")
    if let controls = report.controls, !controls.isEmpty {
        let rates = controls.map(\.rate)
        print(String(format: "Commanded rate range %.3f–%.3fx planned tempo.", rates.min()!, rates.max()!))
        for reason in Set(controls.map(\.reason)).sorted() {
            print("\(controls.filter { $0.reason == reason }.count) commands: \(reason)")
        }
    }
    for notice in report.notices { print(String(format: "%.3f: %@", notice.time, notice.reason)) }
    for index in mismatches.prefix(20) { print("Changed decision \(index), time \(report.decisions[index].time)") }
    if CommandLine.arguments.contains("--audio") {
        let observations = try analyzeAudio(url, report: report)
        print("Re-analyzed audio: \(observations.count) frames, \(observations.filter { $0.pitch != nil }.count) pitched. This starts a fresh analyzer at the excerpt boundary.")
    }
    if !mismatches.isEmpty || !controlMismatches.isEmpty { exit(2) }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
}
