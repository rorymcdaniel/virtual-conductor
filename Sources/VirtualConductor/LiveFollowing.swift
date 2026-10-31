import SwiftUI
import AVFoundation
import ConductorCore

@MainActor protocol FollowingAudio: AnyObject {
    func play(_ segment: AudioSegment, immediate: Bool) throws
    func append(_ segment: AudioSegment)
    func stop()
    func setRate(_ rate: Double)
    func position(host: Double) -> Double
}
extension PerformanceAudio: FollowingAudio {}

@MainActor protocol FollowingInput: AnyObject {
    var storage: CaptureStorage? { get }
    var sampleRate: Double { get }
    var ready: Bool { get }
    var interrupted: (() -> Void)? { get set }
    func enable(device: UInt32, streaming: Bool) throws
    func release()
}
extension InputCapture: FollowingInput {}

struct FollowingConfiguration: Codable {
    var enabled = false
    var solo: MusicXMLStaffID?
    var waits: [WaitPoint] = []
}

/// Owns the live microphone and a prepared, bounded playback timeline. Existing
/// recorded interpretations never share this capture engine or analysis storage.
@MainActor final class LiveFollowing: ObservableObject {
    @Published var configuration = FollowingConfiguration()
    @Published var tolerance: Double = UserDefaults.standard.object(forKey: "following-tolerance") as? Double ?? 10
    @Published var inputID: UInt32 = AudioDevices.defaultID(input: true)
    @Published private(set) var status: FollowingStatus = .following
    @Published private(set) var detail = "Use headphones. Choose your solo staff and microphone."
    @Published private(set) var level: Float = 0
    @Published private(set) var active = false
    private(set) var position = 0.0
    private var plan: FollowingPlan?
    private var prepared: PreparedPerformance?
    private var audio: (any FollowingAudio)?
    private let capture: any FollowingInput
    private let clock: () -> Double
    private let permission: () async -> Bool
    private var tracker = SoloTracker()
    private var tempo = FollowingTempo()
    private var buffers: [Double: AudioSegment] = [:]
    private var boundaries: [Double] = []
    private var audioEnd = 0.0
    private var queuedEnd: Double?
    private var approvedWaits: Set<Double> = []
    private var phase: Phase = .audio
    private var lastTick = 0.0
    private var entered = 0.0
    private var lastPitch: Int?
    private var lastObservation = 0.0
    private var droppedSamples = 0
    private var window: [Float] = []
    private var articulation = LiveArticulation()
    private var articulationWindow: [Float] = []
    private var analyzing = false
    private var generation: UInt64 = 0
    private var key = ""
    var completed: (() -> Void)?
    var failed: ((String) -> Void)?

    private enum Phase { case audio, wait(Double), free(PassageRange), cadenza(CompiledCadenza) }

    init(capture: (any FollowingInput)? = nil, clock: @escaping () -> Double = { PerformanceAudio.hostSeconds },
         permission: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) {
        self.capture = capture ?? InputCapture(); self.clock = clock; self.permission = permission
        if !tolerance.isFinite || !(0...75).contains(tolerance) { tolerance = 10 }
        self.capture.interrupted = { [weak self] in self?.inputFailed() }
    }
    func loadSettings(key: String) {
        stop(); self.key = "following-v1-" + key
        if let data = UserDefaults.standard.data(forKey: self.key),
           let saved = try? JSONDecoder().decode(FollowingConfiguration.self, from: data) { configuration = saved }
        else { configuration = FollowingConfiguration() }
    }
    func save(_ values: FollowingConfiguration, tolerance: Double) throws {
        guard tolerance.isFinite, (0...75).contains(tolerance) else { throw MusicalError("Choose a tempo tolerance from 0–75%.") }
        let data = try JSONEncoder().encode(values)
        configuration = values; self.tolerance = tolerance
        UserDefaults.standard.set(data, forKey: key)
        UserDefaults.standard.set(tolerance, forKey: "following-tolerance")
    }

    func start(prepared: PreparedPerformance, plan: FollowingPlan, audio: any FollowingAudio, position: Double) async throws {
        stop()
        generation &+= 1; let token = generation
        guard await permission() else {
            throw MusicalError("Microphone access is required for live following. Enable it in System Settings → Privacy & Security → Microphone.")
        }
        guard token == generation else { throw CancellationError() }
        let prep = prepared.timing.prepSeconds, midi = prepared.midi
        let points = plan.waits + plan.freePassages.flatMap { [$0.start, $0.end] } + plan.cadenzas.flatMap { [$0.startQuarter, $0.returnQuarter] }
        let limits = Array(Set([0, position, prepared.end] + points.map { prep + midi.seconds(atQuarter: $0) }))
            .filter { $0 >= 0 && $0 <= prepared.end }.sorted()
        let segments = try await Task.detached(priority: .userInitiated) {
            try zip(limits, limits.dropFirst()).map { start, end in
                try PreparedPerformance.makeSegment(source: prepared.source, timing: prepared.timing, position: start, end: end)
            }
        }.value
        guard token == generation else { throw CancellationError() }
        try capture.enable(device: inputID, streaming: true)
        self.prepared = prepared; self.plan = plan; self.audio = audio
        buffers = Dictionary(uniqueKeysWithValues: segments.map { ($0.position, $0) }); boundaries = limits
        self.position = position; active = true; lastTick = clock(); lastObservation = lastTick; droppedSamples = 0
        tracker.reset(notes: plan.notes, quarter: quarter(position))
        approvedWaits = Set(plan.waits.filter { seconds($0) < position - 1e-7 })
        tempo.reset(); audio.setRate(1)
        try enter(at: position, initial: true)
    }

    func stop() {
        generation &+= 1; capture.release(); active = false; analyzing = false
        window = []; articulationWindow = []; articulation = LiveArticulation()
        level = 0; lastPitch = nil; lastObservation = 0
        if let audio { audio.stop(); audio.setRate(1) }
        self.audio = nil; buffers = [:]; boundaries = []; queuedEnd = nil
    }

    private func seconds(_ quarter: Double) -> Double { prepared!.timing.prepSeconds + prepared!.midi.seconds(atQuarter: quarter) }
    private func quarter(_ seconds: Double) -> Double { prepared!.midi.quarter(atSeconds: seconds - prepared!.timing.prepSeconds) }

    private func enter(at location: Double, initial: Bool = false) throws {
        guard let plan, let prepared, let audio else { return }
        position = location; entered = clock(); queuedEnd = nil
        if location >= prepared.end - 1e-7 {
            stop(); status = .finished; completed?(); return
        }
        let q = quarter(location)
        if let cadenza = plan.cadenzas.first(where: { abs($0.startQuarter - q) < 1e-7 }) {
            audio.stop(); phase = .cadenza(cadenza); status = .cadenza
            detail = "Right Arrow · orchestral entrance"; return
        }
        if let wait = plan.waits.first(where: { abs($0 - q) < 1e-7 && !approvedWaits.contains($0) }),
           !plan.cadenzas.contains(where: { q >= $0.startQuarter && q < $0.returnQuarter }) {
            audio.stop(); phase = .wait(wait); status = .waiting
            tracker.reset(notes: plan.notes, quarter: wait, preservingSound: true)
            detail = "Play the expected entrance · Right Arrow to continue"; return
        }
        if let free = plan.freePassages.first(where: { q >= $0.start - 1e-7 && q < $0.end - 1e-7 }) {
            audio.stop(); audio.setRate(1); tempo.reset(); phase = .free(free); status = .waiting
            tracker.reset(notes: plan.notes, quarter: q)
            detail = "Solo passage · play freely · Right Arrow cues the return"; return
        }
        guard let buffer = buffers[location] else { throw MusicalError("Following playback boundary is unavailable. Reset and start again.") }
        phase = .audio; audioEnd = buffer.end
        try audio.play(buffer, immediate: !initial)
        status = .following; detail = "Following within ±\(Int(tolerance))%"
    }

    func cue() {
        guard active else { return }
        do {
            switch phase {
            case .wait(let q):
                approvedWaits.insert(q); try enter(at: seconds(q))
            case .free(let range):
                try returnFromFree(range)
            case .cadenza(let passage):
                // All automatic behavior inside the manually controlled cadenza is skipped.
                approvedWaits.formUnion(plan!.waits.filter { $0 >= passage.startQuarter && $0 <= passage.returnQuarter })
                tracker.reset(notes: plan!.notes, quarter: passage.returnQuarter)
                audio?.setRate(1); tempo.reset(); try enter(at: seconds(passage.returnQuarter))
            case .audio: break
            }
        } catch { fail(error) }
    }

    private func returnFromFree(_ range: PassageRange) throws {
        audio?.setRate(1); tempo.reset()
        // A configured wait at the return still requires its entrance or this explicit cue.
        approvedWaits.insert(range.end)
        tracker.reset(notes: plan!.notes, quarter: range.end)
        try enter(at: seconds(range.end))
    }

    func tick() {
        guard active, let audio, let prepared, let plan else { return }
        let now = clock(), delta = min(0.1, max(0, now - lastTick)); lastTick = now
        guard capture.ready else { inputFailed(); return }
        poll(now: now)
        do {
            switch phase {
            case .audio:
                position = min(audioEnd, audio.position(host: now))
                if position >= audioEnd - 1e-7 {
                    if let next = queuedEnd {
                        audioEnd = next; queuedEnd = nil
                    } else { try enter(at: audioEnd) }
                    return
                }
                let q = quarter(position)
                guard q >= 0 else { return }
                let note = tracker.index.map { plan.notes[$0] }
                let expectingSound = plan.notes.contains { $0.startQuarter <= q && q < $0.endQuarter }
                let age = now - tracker.lastMatch
                let phaseError = note.map { seconds($0.startQuarter) + (now - tracker.lastAttack) * tracker.rate - position } ?? 0
                let rate = tempo.update(delta: delta, tolerance: tolerance / 100, trackedRate: tracker.rate,
                                        phaseError: phaseError, age: expectingSound ? age : 10)
                audio.setRate(rate)
                status = expectingSound && age > 1.5 ? .lost : .following
                detail = status == .lost ? "Keeping moving · listening for your position" : "Following within ±\(Int(tolerance))%"
            case .wait:
                if now - lastObservation > 0.5 || (lastPitch != nil && now - entered > 0.7) { status = .lost }
            case .cadenza: break
            case .free(let range):
                if now - lastObservation > 0.5 { status = .lost; return }
                guard let index = tracker.index else {
                    if lastPitch != nil { status = .lost }
                    return
                }
                let note = plan.notes[index]
                if note.startQuarter >= range.end - 1e-7 { try returnFromFree(range); return }
                let followingNote = index + 1 < plan.notes.count ? plan.notes[index + 1] : nil
                if now - tracker.lastMatch > 0.7 && lastPitch != nil { status = .lost }
                else if status != .lost || now - tracker.lastMatch < 0.3 { status = lastPitch == nil ? .waiting : .following }
                if status == .lost { return }
                if note.endQuarter > range.end + 1e-7 {
                    position = max(seconds(range.start), min(seconds(range.end), seconds(note.startQuarter) + max(0, now - tracker.lastAttack) * tracker.rate))
                    status = .waiting; detail = "Held note crosses the orchestral return · use Right Arrow"
                    return
                }
                let attack = seconds(note.startQuarter)
                position = max(seconds(range.start), min(seconds(min(note.endQuarter, range.end)), attack + max(0, now - tracker.lastAttack) * tracker.rate))
                if let release = tracker.releasedAt {
                    let next = min(range.end, followingNote?.startQuarter ?? range.end)
                    position = min(seconds(next), seconds(note.endQuarter) + max(0, now - release))
                    let needsReturnAttack = followingNote.map { abs($0.startQuarter - range.end) < 1e-7 } ?? false
                    if !needsReturnAttack, next >= range.end, now - release >= max(0, prepared.midi.seconds(atQuarter: range.end) - prepared.midi.seconds(atQuarter: note.endQuarter)) {
                        try returnFromFree(range)
                    }
                }
            }
        } catch { fail(error) }
    }

    private func poll(now: Double) {
        guard let storage = capture.storage else { return }
        level = storage.peak.load(ordering: .relaxed)
        guard !analyzing, let stream = storage.stream else { return }
        let dropped = stream.dropped.load(ordering: .acquiring)
        if dropped != droppedSamples {
            droppedSamples = dropped; _ = stream.drain(); window = []; status = .lost
            return
        }
        let incoming = stream.drain()
        guard !incoming.isEmpty else { return }
        let hop = max(1, Int(capture.sampleRate * 0.01))
        articulationWindow.append(contentsOf: incoming)
        var rearticulated = false
        while articulationWindow.count >= hop {
            let rms = sqrt(articulationWindow.prefix(hop).reduce(0.0) { $0 + Double($1) * Double($1) } / Double(hop))
            let frameTime = now - Double(articulationWindow.count - hop) / capture.sampleRate
            rearticulated = articulation.observe(rms: rms, time: frameTime) || rearticulated
            articulationWindow.removeFirst(hop)
        }
        let size = Int(capture.sampleRate * 0.075)
        window.append(contentsOf: incoming)
        if window.count > size { window.removeFirst(window.count - size) }
        guard window.count >= size else { return }
        analyzing = true
        let samples = window, rate = capture.sampleRate, token = generation
        let tail = incoming.suffix(hop)
        let silent = sqrt(tail.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(tail.count)) < 0.0015
        let attack = rearticulated
        Task {
            let pitch = await Task.detached(priority: .userInitiated) { silent ? nil : LivePitch.detect(samples: samples, sampleRate: rate) }.value
            guard token == generation, active else { return }
            analyzing = false
            guard clock() - now < 0.25 else { status = .lost; return }
            observe(pitch: pitch, time: now, rearticulated: attack)
        }
    }

    func observe(pitch: Int?, time: Double, rearticulated: Bool = false) {
        guard active, let plan, let prepared else { return }
        lastPitch = pitch; lastObservation = time
        if case .cadenza = phase { return }
        let free: Bool
        switch phase { case .audio: free = false; default: free = true }
        let matched = tracker.observe(pitch: pitch, time: time, notes: plan.notes, expectedQuarter: quarter(position), free: free, midi: prepared.midi, rearticulated: rearticulated)
        guard let matched else { return }
        let q = plan.notes[matched].startQuarter
        do {
            switch phase {
            case .wait(let expected):
                if abs(q - expected) < 1e-7 { approvedWaits.insert(expected); try enter(at: seconds(expected)) }
                else { tracker.reset(notes: plan.notes, quarter: expected, preservingSound: true) }
            case .free(let range):
                if let wait = plan.waits.first(where: { $0 >= range.start && $0 <= q && $0 < range.end && !approvedWaits.contains($0) }) {
                    if abs(wait - q) < 1e-7 { approvedWaits.insert(wait) }
                    else { try enter(at: seconds(wait)) }
                }
            case .audio:
                // Queue a recognized near-boundary entrance without restarting the nodes.
                if plan.waits.contains(q), abs(seconds(q) - audioEnd) < 1e-7,
                   audioEnd - position < 0.25, let next = buffers[audioEnd],
                   !plan.freePassages.contains(where: { abs($0.start - q) < 1e-7 }),
                   !plan.cadenzas.contains(where: { abs($0.startQuarter - q) < 1e-7 }) {
                    approvedWaits.insert(q); audio?.append(next); queuedEnd = next.end
                }
            default: break
            }
        } catch { fail(error) }
    }

    private func inputFailed() { fail(MusicalError("Following microphone interrupted. Playback paused; reconnect the input and resume explicitly.")) }
    private func fail(_ error: Error) { stop(); status = .lost; detail = error.localizedDescription; failed?(detail) }
}
