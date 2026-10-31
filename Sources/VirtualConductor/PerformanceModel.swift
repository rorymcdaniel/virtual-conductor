import SwiftUI
import AVFoundation
import CryptoKit
import ConductorCore

struct ConductorSnapshot {
    let time: Double
    let segmentStart: Double
    let timing: PerformanceTiming?
    let state: PerformanceState
}
enum PerformanceState: String { case empty, loading, ready, starting, running, paused, waiting, finished, interrupted, error }

@MainActor final class PerformanceModel: ObservableObject {
    @Published var state: PerformanceState = .empty
    @Published var message = "Choose matching MIDI and WAV exports to begin."
    @Published var devices: [AudioDevice] = []
    @Published var outputID: UInt32 = 0
    @Published var outputMissing = false
    @Published var preparation = 2
    @Published var clicks = false { didSet { audio.clicksEnabled = clicks } }
    @Published var volume = 0.7 { didSet { audio.volume = Float(volume) } }
    @Published var clean = false
    @Published var guide = false
    @Published var utilityOpen = false
    @Published var editorOpen = false
    @Published var followingOpen = false
    @Published var importOpen = false
    @Published var filePanelOpen = false
    @Published var midiURL: URL?
    @Published var wavURL: URL?
    @Published var passages: [CadenzaPassage] = []
    @Published var fingerprint = ""
    @Published var prepared: PreparedPerformance?
    @Published private(set) var longRestSetup = LongRestSetup()
    private var musicXMLURL: URL?
    private var scoreIdentity: URL?
    let audio = PerformanceAudio()
    let following = LiveFollowing()
    let museScore = MuseScoreLink()
    lazy var recording: RecordingModel = {
        let model = RecordingModel(audio: audio)
        model.museScore = museScore
        model.onKeep = { [weak self] files in self?.load(midi: files.midi, wav: files.wav, musicXML: files.musicXML, scoreIdentity: self?.scoreIdentity, preservingTake: true) }
        return model
    }()
    private var run: UInt64 = 0
    private var position = 0.0
    private var segmentStart = 0.0
    private var segmentEnd = 0.0
    private var passageIndex = 0
    private var clockTimer: Timer?
    private var deviceTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var settings = CadenzaSettings()
    var locked: Bool { [.running,.starting,.loading].contains(state) }
    var shortcutsBlocked: Bool { utilityOpen || editorOpen || followingOpen || importOpen || filePanelOpen }
    init() {
        refreshDevices()
        outputID = AudioDevices.defaultID(input: false)
        following.completed = { [weak self] in
            guard let self else { return }
            self.position = self.following.position; self.state = .finished; self.message = "Finished."
        }
        following.failed = { [weak self] text in
            guard let self else { return }
            self.position = self.following.position; self.state = .paused; self.message = text
        }
        audio.interrupted = { [weak self] in self?.interrupt("Audio configuration changed. Select an output before resuming.") }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 0.015, repeats: true) { [weak self] _ in Task { @MainActor in self?.advanceBoundary() } }
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshDevices() } }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.suspend("Mac is sleeping."); self?.interrupt("Mac slept. Reconnect the output before resuming.") } })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.suspend("Display configuration changed.") } })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.suspend("Application hidden.") } })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object:nil, queue:.main) { [weak self] note in
            // The observer is delivered synchronously on the main queue.
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow, window.title == "Virtual Conductor" else { return }
                self?.suspend("Performance window closed."); self?.audio.shutdown()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.suspend("Performance window minimized.") } })
    }
    func refreshDevices() {
        do {
            devices = try AudioDevices.list()
            if let selected = audio.device, !devices.contains(where: { $0.id == selected.id && $0.uid == selected.uid && $0.output }) { interrupt("Selected output disconnected. Choose an available output explicitly.") }
            if audio.device != nil && !audio.ready && state != .loading { interrupt("Output interrupted. Choose an available output explicitly.") }
        } catch { message = error.localizedDescription }
    }
    func chooseOutput() {
        guard !locked else { return }
        guard let device = devices.first(where: { $0.id == outputID && $0.output }) else {
            outputMissing = true; message = "Selected output is unavailable. Choose an available device explicitly."; return
        }
        do {
            audio.stop(); recording.stopPlayback()
            let format = prepared?.source.format ?? AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            try audio.configure(device: device, format: format)
            outputMissing = false
            if state == .interrupted { state = position == 0 ? .ready : .paused }
            message = "Output: \(device.name). Use Test output to check the route."
        } catch { outputMissing = true; message = error.localizedDescription }
    }
    func testOutput() { guard !locked else { return }; do { if !audio.ready { chooseOutput() }; try audio.testTone() } catch { message = error.localizedDescription } }
    func load(midi: URL, wav: URL, musicXML: URL? = nil, scoreIdentity: URL? = nil, preservingTake: Bool = false, linked: Bool = false) {
        if !preservingTake && !linked { museScore.disconnect() }
        run &+= 1; let token = run
        let cueToken = longRestSetup.beginLoading()
        following.stop(); audio.stop(); recording.close(); state = .loading; message = "Reading exports and preparing audio…"
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { () -> (MIDIFile,AVAudioPCMBuffer,String,LongRestSetup.Loaded) in
                    let data = try Data(contentsOf: midi)
                    let parsed = try MIDIFile(data: data)
                    return (parsed,try PreparedPerformance.load(wav), SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined(), LongRestSetup.Loaded(musicXML: musicXML, identity: scoreIdentity ?? musicXML, midi: parsed, keptTiming: preservingTake))
                }.value
                guard token == run else { return }
                var saved: [CadenzaPassage] = []; var warning = ""
                do { saved = preservingTake ? passages : try settings.load(fingerprint: result.2); _ = try compileCadenzas(saved,midi:result.0,audioDuration:Double(result.1.frameLength)/result.1.format.sampleRate) }
                catch { warning = " Saved settings could not load: \(error.localizedDescription)"; saved = [] }
                let prep = preparation, values = saved
                let new = try await Task.detached { try PreparedPerformance(midi:result.0,source:result.1,preparation:prep,passages:values) }.value
                guard token == run else { return }
                longRestSetup.finishLoading(result.3, generation: cueToken)
                let xmlHash = result.3.document.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "no-xml"
                following.loadSettings(key: result.2 + "-" + xmlHash)
                if let solo = following.configuration.solo { longRestSetup.selectStaff(solo) }
                self.musicXMLURL = musicXML; self.scoreIdentity = scoreIdentity
                prepared = new; fingerprint = result.2; passages = saved; midiURL = midi; wavURL = wav
                if preservingTake { recording.refreshLinkedScore(result.0, fingerprint: result.2); if utilityOpen { recording.open() } }
                else { recording.setScore(result.0, fingerprint:result.2) }
                position = 0; segmentStart = 0; passageIndex = 0; state = .ready
                if !outputMissing { chooseOutput() }
                message = "\(result.0.measures) measures · opening ♩ = \(String(format:"%.1f",result.0.openingBPM)). Ready.\(warning)"
                if new.duration + 0.1 < new.midi.duration { message += " Audio ends before MIDI; check the matching exports." }
                importOpen = false
            } catch { guard token == run else { return }; longRestSetup.failLoading(generation: cueToken); state = .error; message = "Could not load exports: \(error.localizedDescription)" }
        }
    }
    func reload() { if let midiURL, let wavURL { load(midi:midiURL,wav:wavURL,musicXML:musicXMLURL,scoreIdentity:scoreIdentity,linked:museScore.connected) } }
    func selectLongRestStaff(_ id: MusicXMLStaffID?) {
        longRestSetup.selectStaff(id)
        following.configuration.solo = id
    }
    func setLongRestThreshold(_ value: Int) { longRestSetup.setThreshold(value) }
    func reset() {
        run &+= 1; following.stop(); audio.stop(); audio.setRate(1); position = 0; segmentStart = 0; passageIndex = 0
        state = prepared == nil ? .empty : .ready
        message = prepared == nil ? "Choose matching MIDI and WAV exports." : "Ready. One upbeat precedes preparation."
    }
    func rebuild(passages values: [CadenzaPassage]? = nil) {
        guard let old = prepared else { return }
        let selected = values ?? passages, prep = preparation
        run &+= 1; let token = run; following.stop(); audio.stop(); state = .loading
        Task {
            do {
                let new = try await Task.detached { try PreparedPerformance(midi:old.midi,source:old.source,preparation:prep,passages:selected) }.value
                guard token == run else { return }
                prepared = new; passages = selected; reset()
            } catch { guard token == run else { return }; state = .error; message = error.localizedDescription }
        }
    }
    func elapsed(host: Double = PerformanceAudio.hostSeconds) -> Double {
        if following.active { return following.position }
        return state == .running ? min(segmentEnd,max(segmentStart,host-audio.audibleOrigin)) : position
    }
    func snapshot(displayHost: Double) -> ConductorSnapshot { ConductorSnapshot(time:elapsed(host:displayHost),segmentStart:segmentStart,timing:prepared?.timing,state:state) }
    func advanceBoundary() {
        if following.active { following.tick(); return }
        guard state == .running, let prepared else { return }
        if PerformanceAudio.hostSeconds - audio.audibleOrigin >= segmentEnd {
            position = segmentEnd; audio.stop()
            if passageIndex < prepared.passages.count { state = .waiting; message = "Cadenza — press ArrowRight at the orchestral entrance." }
            else { state = .finished; message = "Finished." }
        }
    }
    func pause() { advanceBoundary(); if state == .running { position = elapsed(); run &+= 1; following.stop(); audio.stop(); state = .paused } }
    func toggle() {
        guard !shortcutsBlocked, !outputMissing else { return }
        advanceBoundary()
        if state == .running { pause(); return }
        guard let prepared, [.ready,.paused,.finished].contains(state) else { return }
        if state == .finished { reset() }
        if following.configuration.enabled { startFollowing(prepared); return }
        let start = position, index = passageIndex
        let end = prepared.segments[index].end
        run &+= 1; let token = run; state = .starting
        Task {
            do {
                let segment: AudioSegment
                if abs(start-prepared.segments[index].position) < 1e-8 { segment = prepared.segments[index] }
                else { segment = try await Task.detached { try PreparedPerformance.makeSegment(source:prepared.source,timing:prepared.timing,position:start,end:end) }.value }
                guard token == run else { return }
                try begin(segment,immediate:false)
            } catch { guard token == run else { return }; state = .paused; message = error.localizedDescription }
        }
    }
    private func begin(_ segment: AudioSegment, immediate: Bool) throws {
        audio.setRate(1)
        try audio.play(segment,immediate:immediate)
        segmentStart = segment.position; position = segment.position; segmentEnd = segment.end; state = .running
        message = "Performing · original-speed WAV and MIDI tempo map."
    }
    func cue() {
        guard !shortcutsBlocked, !outputMissing else { return }
        if following.active { following.tick(); following.cue(); return }
        advanceBoundary()
        guard state == .waiting, let prepared, audio.ready else { return }
        do { try begin(prepared.segments[passageIndex+1],immediate:true); passageIndex += 1 }
        catch { message = error.localizedDescription }
    }
    func interrupt(_ text: String) {
        if state == .running { position = elapsed() }
        run &+= 1; following.stop(); audio.shutdown(); recording.stopPlayback(); outputMissing = true
        if state != .waiting && prepared != nil { state = .interrupted }
        message = text
    }
    func suspend(_ reason: String) {
        pause()
        if state == .starting { run &+= 1; following.stop(); state = .paused; audio.stop() }
        closeRecording(); message = reason + " Resume explicitly when ready."
    }
    func openRecording() {
        pause()
        if state == .starting { run &+= 1; following.stop(); state = .paused }
        audio.stop(); utilityOpen = true; recording.open()
    }
    func closeRecording() { recording.close(); utilityOpen = false }
    func followingPlan(configuration: FollowingConfiguration) throws -> FollowingPlan {
        guard let score = longRestSetup.score else {
            throw MusicalError(longRestSetup.availability.replacingOccurrences(of: "Long-rest cues", with: "Live following"))
        }
        guard let solo = configuration.solo, let prepared else {
            throw MusicalError("Load matching MusicXML and choose your solo staff before enabling live following.")
        }
        return try FollowingPlan(score: score, solo: solo, waits: configuration.waits, cadenzas: prepared.passages)
    }
    func saveFollowing(_ values: FollowingConfiguration, tolerance: Double) throws {
        if values.enabled || !values.waits.isEmpty { _ = try followingPlan(configuration: values) }
        try following.save(values, tolerance: tolerance)
        longRestSetup.selectStaff(values.solo); followingOpen = false; reset()
    }
    private func startFollowing(_ prepared: PreparedPerformance) {
        do {
            let plan = try followingPlan(configuration: following.configuration)
            run &+= 1; let token = run; let start = position
            state = .starting; message = "Preparing live following and microphone…"
            Task {
                do {
                    try await following.start(prepared: prepared, plan: plan, audio: audio, position: start)
                    guard token == run else { return }
                    segmentStart = start; state = .running
                    message = "Live following · headphones · Right Arrow releases waits or cues a solo return."
                } catch {
                    guard token == run else { return }
                    following.stop(); state = .paused; message = error.localizedDescription
                }
            }
        } catch { message = error.localizedDescription }
    }
    func savePassages(_ values: [CadenzaPassage]) throws -> [CompiledCadenza] {
        guard let prepared else { return [] }
        return try compileCadenzas(values,midi:prepared.midi,audioDuration:prepared.duration)
    }
    func commitPassages(_ values: [CadenzaPassage]) throws {
        try settings.save(values,fingerprint:fingerprint); editorOpen = false; rebuild(passages:values)
    }
    func importSettings() {
        guard let prepared else { return }
        filePanelOpen = true; defer { filePanelOpen = false }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            do { let values = try settings.importBridge(data:Data(contentsOf:url),fingerprint:fingerprint,midi:prepared.midi,audioDuration:prepared.duration); rebuild(passages:values) }
            catch { message = error.localizedDescription }
        }
    }
}
