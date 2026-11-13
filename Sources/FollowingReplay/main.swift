import Foundation
import AVFoundation
import ConductorCore

// No GUI, microphone, network, or writes. Replays a saved local report.
do {
    guard CommandLine.arguments.count >= 2 else { throw MusicalError("Usage: FollowingReplay /path/to/report.json [--audio]") }
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let report = try FollowingDiagnostic.decode(Data(contentsOf: url))
    let mismatches = report.replay()
    print("Replayed \(report.decisions.count) recognition decisions; \(mismatches.count) changed results.")
    for notice in report.notices { print(String(format: "%.3f: %@", notice.time, notice.reason)) }
    for index in mismatches.prefix(20) { print("Changed decision \(index), time \(report.decisions[index].time)") }
    if CommandLine.arguments.contains("--audio") {
        guard report.audioStart != nil else { throw MusicalError("This report contains no opted-in audio.") }
        let file = try AVAudioFile(forReading: url.deletingLastPathComponent().appendingPathComponent("audio.wav"))
        guard file.length > 0, file.length <= 384000 * 15,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw MusicalError("Invalid audio excerpt.") }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { throw MusicalError("Cannot decode excerpt.") }
        var analyzer = SoloAudioAnalyzer(sampleRate: file.processingFormat.sampleRate)
        let observations = analyzer.process(Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))))
        print("Re-analyzed audio: \(observations.count) frames, \(observations.filter { $0.pitch != nil }.count) pitched. This starts a fresh analyzer at the excerpt boundary.")
    }
    if !mismatches.isEmpty { exit(2) }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
}
