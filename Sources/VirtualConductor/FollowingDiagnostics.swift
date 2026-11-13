import SwiftUI
import ConductorCore

/// Recent, bounded local evidence. Audio is collected only with explicit opt-in.
@MainActor final class FollowingDiagnostics: ObservableObject {
    @Published var includeAudio = false {
        didSet { if !includeAudio { audioChunks = []; audioCount = 0 } }
    }
    @Published private(set) var available = false
    @Published private(set) var saving = false
    @Published private(set) var message = "Reports stay on this Mac. Audio is off unless enabled here."
    @Published private(set) var savedURL: URL?
    private(set) var report: FollowingDiagnostic?
    private var audioChunks: [(start: Double, samples: [Float])] = []
    private var audioCount = 0
    let root: URL
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VirtualConductor/Diagnostics", isDirectory: true)) { self.root = root }
    func begin(sampleRate: Double, tolerance: Double, plan: FollowingPlan, midi: MIDIFile) {
        report = FollowingDiagnostic(sampleRate: sampleRate, tolerance: tolerance, notes: plan.notes, midi: midi)
        audioChunks = []; audioCount = 0; available = false; savedURL = nil
        message = includeAudio ? "Recent diagnostic audio enabled · kept locally when you save." : "Recent following decisions available after playing · audio off."
    }
    func record(_ decision: FollowingDecision) {
        guard report != nil else { return }
        report!.decisions.append(decision)
        if report!.decisions.count > 3000 { report!.decisions.removeFirst(100) }
        if !available { available = true }
    }
    func notice(_ reason: String, time: Double) {
        guard report != nil else { return }
        report!.notices.append(DiagnosticNotice(time: time, reason: reason))
        if report!.notices.count > 200 { report!.notices.removeFirst() }
        if !available { available = true }
    }
    func capture(_ samples: [Float], start: Double) {
        guard includeAudio, let report, !samples.isEmpty else { return }
        audioChunks.append((start, samples)); audioCount += samples.count
        let limit = Int(report.sampleRate * 15)
        while audioCount > limit, !audioChunks.isEmpty {
            let excess = min(audioCount - limit, audioChunks[0].samples.count)
            if excess == audioChunks[0].samples.count { audioChunks.removeFirst() }
            else {
                audioChunks[0].samples.removeFirst(excess)
                audioChunks[0].start += Double(excess) / report.sampleRate
            }
            audioCount -= excess
        }
    }
    func audioDiscontinuity() { audioChunks = []; audioCount = 0 }
    func snapshot() -> (FollowingDiagnostic, [Float])? {
        guard var report else { return nil }
        let chunks = includeAudio ? audioChunks : []
        report.audioStart = chunks.first?.start
        report.audioEnd = chunks.last.map { $0.start + Double($0.samples.count) / report.sampleRate }
        return (report, chunks.flatMap(\.samples))
    }
    func save() {
        guard !saving, available, let (snapshot, samples) = snapshot() else { return }
        saving = true
        let root = root
        Task {
            do {
                let url = try await Task.detached(priority: .utility) {
                    let dir = root.appendingPathComponent("Following-" + UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    if !samples.isEmpty { try Interpretation.encodeWAV(samples: samples, sampleRate: snapshot.sampleRate).write(to: dir.appendingPathComponent("audio.wav"), options: .atomic) }
                    try snapshot.encoded().write(to: dir.appendingPathComponent("report.json"), options: .atomic)
                    let text = "Local following diagnostic. report.json contains score notes, timing, recognition decisions and interruption notices. " +
                        (samples.isEmpty ? "No microphone audio was saved." : "audio.wav contains up to 15 seconds of opted-in microphone audio.") +
                        "\nReplay: '/Applications/Virtual Conductor.app/Contents/MacOS/FollowingReplay' '/path/to/this/folder/report.json'\nAdd --audio to re-analyze the audio excerpt. Replay checks recognition decisions, not acoustic output latency.\n"
                    try text.write(to: dir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
                    return dir
                }.value
                savedURL = url; message = "Diagnostic saved locally" + (samples.isEmpty ? " without audio." : " with a recent audio excerpt.")
            } catch { message = "Diagnostic could not be saved: " + error.localizedDescription }
            saving = false
        }
    }
    func showSaved() { if let savedURL { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) } }
}

struct FollowingDiagnosticsControls: View {
    @ObservedObject var diagnostics: FollowingDiagnostics
    let active: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Include recent audio in diagnostics", isOn: $diagnostics.includeAudio).disabled(active)
                Button(diagnostics.saving ? "Saving…" : "Save following report", action: diagnostics.save)
                    .disabled(!diagnostics.available || diagnostics.saving)
                if diagnostics.savedURL != nil { Button("Show report", action: diagnostics.showSaved) }
            }
            Text(diagnostics.message).font(.caption).foregroundStyle(.secondary)
        }
    }
}
