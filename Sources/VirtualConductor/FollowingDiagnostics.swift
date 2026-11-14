import SwiftUI
import ConductorCore

/// Recent, bounded local evidence. Audio is collected only with explicit opt-in.
@MainActor final class FollowingDiagnostics: ObservableObject {
    @Published var includeAudio = false {
        didSet {
            if !includeAudio {
                audioChunks = []; audioCount = 0
                if var failed = failedSnapshot {
                    failed.0.audioStart = nil; failed.0.audioEnd = nil; failed.1 = []
                    failedSnapshot = failed
                }
            }
        }
    }
    @Published private(set) var available = false
    @Published private(set) var saving = false
    @Published private(set) var message = "Reports stay on this Mac. Audio is off unless enabled here."
    @Published private(set) var savedURL: URL?
    private(set) var report: FollowingDiagnostic?
    private var audioChunks: [(start: Double, samples: [Float])] = []
    private var audioCount = 0
    private var session = UUID()
    private var incident: String?
    private var incidentStart = 0.0
    private var incidentSaved = false
    private var automaticCount = 0
    private var lastAutomaticTime = -Double.infinity
    private var failedSnapshot: (FollowingDiagnostic, [Float])?
    var canSave: Bool { available || failedSnapshot != nil }
    let root: URL
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VirtualConductor/Diagnostics", isDirectory: true)) { self.root = root }
    func begin(sampleRate: Double, tolerance: Double, plan: FollowingPlan, midi: MIDIFile) {
        session = UUID(); incident = nil; incidentSaved = false; automaticCount = 0; lastAutomaticTime = -.infinity
        report = FollowingDiagnostic(sampleRate: sampleRate, tolerance: tolerance, notes: plan.notes, midi: midi)
        audioChunks = []; audioCount = 0; available = false; savedURL = nil
        if failedSnapshot == nil {
            message = includeAudio ? "Problem reports save automatically on this Mac · recent audio enabled." : "Problem reports save automatically on this Mac · audio off."
        }
    }
    func record(_ decision: FollowingDecision) {
        guard report != nil else { return }
        report!.decisions.append(decision)
        if report!.decisions.count > 3000 { report!.decisions.removeFirst(100) }
        if !available { available = true }
    }
    func notice(_ reason: String, time: Double, kind: DiagnosticNotice.Kind = .information) {
        guard report != nil else { return }
        report!.notices.append(DiagnosticNotice(time: time, reason: reason, kind: kind))
        if report!.notices.count > 200 { report!.notices.removeFirst() }
        if !available { available = true }
    }
    func recordControl(_ decision: FollowingControlDecision) {
        guard report != nil else { return }
        report!.controls?.append(decision)
        if (report!.controls?.count ?? 0) > 3000 { report!.controls?.removeFirst(100) }
        available = true
    }

    /// One snapshot per sustained incident, at most three per performance and
    /// no more than one every 30 seconds. Ordinary waits/cadenzas are not faults.
    func monitor(status: FollowingStatus, time: Double, atTempoLimit: Bool = false) {
        let reason: String?
        let delay: Double
        if status == .lost { reason = "Tracking lost"; delay = 0 }
        else if status == .holding { reason = "Holding tempo for a sustained uncertain phrase"; delay = 3 }
        else if status == .following && atTempoLimit { reason = "Playback stayed at the tempo tolerance limit"; delay = 2 }
        else { reason = nil; delay = 0 }
        if incident != reason {
            incident = reason; incidentStart = time; incidentSaved = false
        }
        guard let reason, !incidentSaved, time - incidentStart >= delay else { return }
        incidentSaved = preserveIncident(reason, time: time)
    }

    @discardableResult func preserveIncident(_ reason: String, time: Double) -> Bool {
        guard !saving, failedSnapshot == nil, automaticCount < 3,
              time - lastAutomaticTime >= 30, report != nil else { return false }
        notice("Automatic snapshot: " + reason, time: time)
        guard let snapshot = snapshot() else { return false }
        automaticCount += 1; lastAutomaticTime = time
        persist(snapshot, automatic: true)
        return true
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
        guard !saving, let snapshot = failedSnapshot ?? (available ? snapshot() : nil) else { return }
        persist(snapshot, automatic: false)
    }

    private func persist(_ captured: (FollowingDiagnostic, [Float]), automatic: Bool) {
        saving = true
        let root = root, capturedSession = session
        Task {
            do {
                let url = try await Task.detached(priority: .utility) {
                    try Self.write(captured, root: root, automatic: automatic)
                }.value
                failedSnapshot = nil
                if capturedSession == session {
                    savedURL = url
                    message = (automatic ? "Problem report saved automatically" : "Diagnostic saved locally") +
                        (captured.1.isEmpty ? " without audio." : " with a recent audio excerpt.")
                }
            } catch {
                var retained = captured
                if !includeAudio {
                    retained.0.audioStart = nil; retained.0.audioEnd = nil; retained.1 = []
                }
                failedSnapshot = retained
                message = "Report could not be saved. Evidence kept in memory; Save following report retries. " + error.localizedDescription
            }
            saving = false
        }
    }

    private nonisolated static func write(_ captured: (FollowingDiagnostic, [Float]), root: URL, automatic: Bool) throws -> URL {
        let (snapshot, samples) = captured, fm = FileManager.default
        let parent = automatic ? root.appendingPathComponent("Automatic", isDirectory: true) : root
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let identifier = UUID().uuidString
        let staging = parent.appendingPathComponent(".pending-" + identifier, isDirectory: true)
        let destination = parent.appendingPathComponent((automatic ? "Auto-" : "Following-") + identifier, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        if !samples.isEmpty { try Interpretation.encodeWAV(samples: samples, sampleRate: snapshot.sampleRate).write(to: staging.appendingPathComponent("audio.wav"), options: .atomic) }
        try snapshot.encoded().write(to: staging.appendingPathComponent("report.json"), options: .atomic)
        let text = "Local following diagnostic: recognition, commanded playback tempo, correction evidence, and interruptions. " +
            (samples.isEmpty ? "No microphone audio was saved." : "audio.wav contains up to 15 seconds of opted-in microphone audio.") +
            "\nReplay: '/Applications/Virtual Conductor.app/Contents/MacOS/FollowingReplay' '/path/to/this/folder/report.json'\nAdd --audio to re-analyze audio. Command replay does not measure acoustic output latency.\n" +
            (automatic ? "Automatic reports rotate to keep the newest 12; manually saved reports are never pruned.\n" : "Manually saved report; not automatically pruned.\n")
        try text.write(to: staging.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        try fm.moveItem(at: staging, to: destination)
        if automatic {
            let files = try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.creationDateKey])
                .filter { $0.lastPathComponent.hasPrefix("Auto-") && UUID(uuidString: String($0.lastPathComponent.dropFirst(5))) != nil &&
                    fm.fileExists(atPath: $0.appendingPathComponent("report.json").path) }
                .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) >
                    ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            for old in files.dropFirst(12) { try fm.removeItem(at: old) }
        }
        return destination
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
                    .disabled(!diagnostics.canSave || diagnostics.saving)
                if diagnostics.savedURL != nil { Button("Show report", action: diagnostics.showSaved) }
            }
            Text(diagnostics.message).font(.caption).foregroundStyle(.secondary)
        }
    }
}
