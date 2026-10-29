import SwiftUI
import AVFoundation
import ConductorCore

struct RecordedTake {
    let samples: [Float]
    let sampleRate: Double
    let range: PassageRange
    var duration: Double { Double(samples.count)/sampleRate }
}
@MainActor final class RecordingModel: ObservableObject {
    @Published var inputs: [AudioDevice] = []
    @Published var inputID: UInt32 = 0
    @Published var inputReady = false
    @Published var recording = false
    @Published var busy = false
    @Published var playing = false
    @Published var level: Float = 0
    @Published var message = "Enable an input to begin. No microphone monitoring."
    @Published var take: RecordedTake?
    @Published var startMeasure = 1
    @Published var startBeat = 1
    @Published var endMeasure = 5
    @Published var endBeat = 1
    @Published var trackIndex = -1
    @Published var tracks: [MIDITrack] = []
    @Published var beats: [BeatTime] = [] { didSet { museScore?.invalidatePreview(); heardPreview = false } }
    @Published var approved = false
    @Published var manualStart = 0.0
    @Published var manualEnd = 0.0
    @Published var playbackTime = 0.0
    var museScore: MuseScoreLink?
    var onKeep: ((RehearsalFiles) -> Void)?
    @Published var heardPreview = false
    @Published var accompanimentPlaying = false
    private var playbackDuration = 0.0
    private let capture = InputCapture()
    private let audio: PerformanceAudio
    private let permission: () async -> Bool
    private let copySamples: (CaptureStorage) async -> [Float]
    private var midi: MIDIFile?
    private var fingerprint = ""
    private var generation: UInt64 = 0
    private var takeGeneration: UInt64 = 0
    private var finalizing = false
    private var visible = false
    private var recordRange: PassageRange?
    private var timer: Timer?
    private var analysis: Task<Void,Never>?
    init(audio: PerformanceAudio, permission: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for:.audio) }, copySamples: @escaping (CaptureStorage) async -> [Float] = { storage in await Task.detached {
            while storage.receiving.load(ordering:.acquiring) { await Task.yield() }
            return Array(UnsafeBufferPointer(start:storage.samples,count:storage.count.load(ordering:.acquiring)))
        }.value }) {
        self.audio = audio; self.permission = permission; self.copySamples = copySamples
        capture.interrupted = { [weak self] in self?.captureInterrupted() }
        timer = Timer.scheduledTimer(withTimeInterval:0.04,repeats:true) { [weak self] _ in Task { @MainActor in self?.update() } }
    }
    func setScore(_ score: MIDIFile, fingerprint: String) {
        guard fingerprint != self.fingerprint else { return }
        close(); takeGeneration &+= 1; finalizing = false; busy = false
        self.fingerprint = fingerprint; midi = score; tracks = score.tracks; take = nil; beats = []; approved = false
        startMeasure = 1; startBeat = 1; endMeasure = min(5, score.measures + 1); endBeat = 1
        let horns = tracks.indices.filter { tracks[$0].name.range(of:"horn|валторн",options:[.regularExpression,.caseInsensitive]) != nil && tracks[$0].notes > 3 && tracks[$0].noteEvents.first?.startQuarter == 0 }
        trackIndex = horns.count == 1 ? horns[0] : -1
    }
    func open() { visible = true; inputs = (try? AudioDevices.list().filter(\.input)) ?? [] }
    func enableInput() {
        guard !recording, !busy, !finalizing else { return }
        inputs = (try? AudioDevices.list().filter(\.input)) ?? inputs
        generation &+= 1; let token = generation; busy = true; stopPlayback()
        Task {
            let granted = await permission()
            guard token == generation, visible else { return }
            busy = false
            guard granted else { message = "Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone."; return }
            do { try capture.enable(device:inputID == 0 ? AudioDevices.defaultID(input:true) : inputID); inputReady = true; message = "Input active. Check the level, then Record." }
            catch { inputReady = false; message = error.localizedDescription }
        }
    }
    func changeInput() { generation &+= 1; capture.release(); inputReady = false; busy = finalizing; level = 0 }
    func record() {
        guard !busy, !recording, let midi else { return }
        do {
            takeGeneration &+= 1
            recordRange = try Interpretation.range(startMeasure:startMeasure,startBeat:startBeat,endMeasure:endMeasure,endBeat:endBeat,midi:midi)
            stopPlayback(); analysis?.cancel(); try capture.start(); recording = true; message = "Recording — play freely, then Stop."
        } catch { message = error.localizedDescription }
    }
    func stop() {
        stopPlayback()
        guard recording else { return }
        recording = false; inputReady = false
        guard let (storage,rate) = capture.finish(), let range = recordRange else { return }
        finalizeCapture(storage,rate:rate,range:range)
    }
    func finalizeCapture(_ storage: CaptureStorage, rate: Double, range: PassageRange) {
        let captureToken = takeGeneration
        finalizing = true; busy = true
        Task {
            let samples = await copySamples(storage)
            guard captureToken == takeGeneration else { return }
            finalizing = false; busy = false
            guard !samples.isEmpty else { message = "No samples captured; prior take retained."; return }
            take = RecordedTake(samples:samples,sampleRate:rate,range:range); beats = []; approved = false
            manualStart = 0; manualEnd = Double(samples.count)/rate
            message = "Take retained for this session. Listen, analyze or set timing manually."
        }
    }
    func captureInterrupted() {
        takeGeneration &+= 1; generation &+= 1; finalizing = false
        recording = false; busy = false; capture.release(); inputReady = false; level = 0
        message = "Input interrupted. Previous successful take retained; enable input again before recording."
    }
    func update() {
        if inputReady && !capture.ready { captureInterrupted() }
        level = capture.storage?.peak.load(ordering:.relaxed) ?? 0
        if recording, let storage = capture.storage, storage.count.load(ordering:.acquiring) >= storage.capacity { stop() }
        if playing, let take {
            playbackTime = max(0,PerformanceAudio.hostSeconds-(accompanimentPlaying ? previewOrigin : audio.auxiliaryOrigin))
            if !audio.ready || playbackTime >= (accompanimentPlaying ? playbackDuration : take.duration) { stopPlayback() }
        }
    }
    func stopPlayback() { if playing { audio.stop() }; playing = false; accompanimentPlaying = false }
    func play() {
        if playing { stopPlayback(); return }
        guard !recording,!busy,let take else { return }
        do { if !beats.isEmpty { try Interpretation.validate(beats,duration:take.duration) }; try audio.playTake(samples:take.samples,sampleRate:take.sampleRate); playbackTime = 0; playing = true }
        catch { message = error.localizedDescription }
    }
    func analyze() {
        guard !busy,!recording,let take,tracks.indices.contains(trackIndex) else { return }
        stopPlayback(); approved = false; busy = true; generation &+= 1; let token = generation
        let notes = tracks[trackIndex].noteEvents
        let task = Task.detached { try Interpretation.analyze(samples:take.samples,sampleRate:take.sampleRate,reference:notes,range:take.range) }
        analysis = Task {
            do {
                let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard token == generation, visible else { return }
                beats = result.beats; manualStart = beats.first!.time; manualEnd = beats.last!.time
                message = "\(result.matched) of \(result.total) notes matched. \(result.warning)"; busy = false
            } catch { guard token == generation else { return }; busy = false; message = error.localizedDescription + " Use manual timing if needed." }
        }
    }
    func manual() { guard let take else { return }; proposal { try Interpretation.manual(range:take.range,start:manualStart,end:manualEnd,duration:take.duration) } }
    func simplify() { guard let take else { return }; proposal { try Interpretation.simplify(beats,duration:take.duration) } }
    private func proposal(_ work: () throws -> [BeatTime]) { stopPlayback(); approved = false; do { beats = try work(); message = "Draft ready. Hear the accompaniment, or adjust timing if needed." } catch { message = error.localizedDescription } }
    func editBeat(index: Int, time: Double) { guard beats.indices.contains(index) else { return }; stopPlayback(); approved = false; beats[index].time = time }
    func changeTrack() { generation &+= 1; analysis?.cancel(); beats = []; approved = false; busy = false }
    func approve() { guard let take else { return }; do { try Interpretation.validate(beats,duration:take.duration); approved = true; message = "Approved for CSV export. Score and performance are unchanged." } catch { approved = false; message = error.localizedDescription } }
    func refreshLinkedScore(_ score: MIDIFile, fingerprint: String) {
        midi = score; self.fingerprint = fingerprint; tracks = score.tracks
    }
    func hearAccompaniment() {
        guard !busy, !recording, let take, let midi, let link = museScore else { return }
        stopPlayback(); busy = true; message = "Rendering accompaniment with your timing…"; generation &+= 1; let token = generation
        Task {
            do {
                let files = try await link.makePreview(beats: beats, take: take, midi: midi)
                guard token == generation else { busy = false; return }
                let previewMIDI = try MIDIFile(data: Data(contentsOf: files.midi))
                let source = try PreparedPerformance.load(files.wav)
                let timing = try PerformanceTiming(midi: previewMIDI, preparatoryMeasures: 0)
                let start = previewMIDI.seconds(atQuarter: take.range.start)
                let end = min(Double(source.frameLength)/source.format.sampleRate, previewMIDI.seconds(atQuarter: take.range.end))
                let segment = try PreparedPerformance.makeSegment(source: source, timing: timing, position: start, end: end)
                try audio.play(segment, immediate: true)
                // Timer uses the same host clock as normal playback, offset to this passage.
                playbackDuration = end-start; playbackTime = 0
                previewOrigin = audio.audibleOrigin + start
                accompanimentPlaying = true; playing = true; heardPreview = true; busy = false
                message = "Listen to the accompaniment. Keep it if it follows your playing."
            } catch { busy = false; message = error.localizedDescription }
        }
    }
    private var previewOrigin = 0.0
    func keepInterpretation() {
        guard heardPreview, !busy, let link = museScore else { return }
        stopPlayback(); busy = true
        Task {
            do {
                let files = try await link.keep(); busy = false; heardPreview = false
                message = link.message; onKeep?(files)
            } catch { busy = false; message = error.localizedDescription }
        }
    }
    func exportCSV() {
        guard approved, let take, let midi else { return }
        do { let text = try Interpretation.csv(beats:beats,range:take.range,midi:midi,duration:take.duration); try save(Data(text.utf8),name:"virtual-conductor-tempo-map.csv") } catch { message = error.localizedDescription }
    }
    func exportWAV() { guard let take else { return }; do { try save(Interpretation.encodeWAV(samples:take.samples,sampleRate:take.sampleRate),name:"virtual-conductor-solo-take.wav") } catch { message = error.localizedDescription } }
    private func save(_ data:Data,name:String) throws { let panel = NSSavePanel(); panel.nameFieldStringValue = name; if panel.runModal() == .OK, let url = panel.url { try data.write(to:url,options:.atomic) } }
    func close() { visible = false; generation &+= 1; analysis?.cancel(); stop(); capture.release(); inputReady = false; busy = finalizing; level = 0 }
}
