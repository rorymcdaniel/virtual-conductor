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
    func startStreaming(device: UInt32) async throws
    func release()
}
extension InputCapture: FollowingInput {}

/// Owns the live microphone and a prepared, bounded playback timeline. Existing
/// recorded interpretations never share this capture engine or analysis storage.
@MainActor final class LiveFollowing: ObservableObject {
    @Published var tolerance: Double {
        didSet { defaults.set(tolerance, forKey: "following-tolerance") }
    }
    let diagnostics: FollowingDiagnostics
    private let defaults: UserDefaults
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
    private var analyzer: SoloAudioAnalyzer?
    private var analysisOrigin: Double?
    private var analysisSamples = 0
    private var analyzing = false
    private var generation: UInt64 = 0
    var completed: (() -> Void)?
    var failed: ((String) -> Void)?

    private enum Phase { case audio, wait(Double), free(PassageRange), cadenza(CompiledCadenza) }

    init(diagnostics: FollowingDiagnostics? = nil, capture: (any FollowingInput)? = nil, clock: @escaping () -> Double = { PerformanceAudio.hostSeconds },
         permission: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) },
         defaults: UserDefaults = .standard) {
        self.capture = capture ?? InputCapture(); self.clock = clock; self.permission = permission
        self.defaults = defaults
        self.diagnostics = diagnostics ?? FollowingDiagnostics()
        let saved = defaults.object(forKey: "following-tolerance") as? Double ?? 10
        tolerance = saved.isFinite && (0...75).contains(saved) ? saved : 10
        self.capture.interrupted = { [weak self] in self?.inputFailed() }
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
        var releases = Dictionary(uniqueKeysWithValues: plan.freePassages.compactMap { gap -> (Double, Double)? in
            guard !plan.waits.contains(gap.start), !plan.cadenzas.contains(where: { $0.startQuarter == gap.start }) else { return nil }
            return (prep + midi.seconds(atQuarter: gap.start), prep + midi.seconds(atQuarter: gap.end))
        })
        for passage in plan.cadenzas {
            releases[prep + passage.startSeconds] = PreparedPerformance.cadenzaReleaseEnd(passage, timing: prepared.timing)
        }
        let releaseLimits = releases
        let segments = try await Task.detached(priority: .userInitiated) {
            try zip(limits, limits.dropFirst()).map { start, end in
                try PreparedPerformance.makeSegment(source: prepared.source, timing: prepared.timing, position: start, end: end, ringOutUntil: releaseLimits[end])
            }
        }.value
        guard token == generation else { throw CancellationError() }
        try await capture.startStreaming(device: inputID)
        guard token == generation else { throw CancellationError() }
        self.prepared = prepared; self.plan = plan; self.audio = audio
        buffers = Dictionary(uniqueKeysWithValues: segments.map { ($0.position, $0) }); boundaries = limits
        self.position = position; active = true; lastTick = clock(); lastObservation = lastTick; droppedSamples = 0
        diagnostics.begin(sampleRate: capture.sampleRate, tolerance: tolerance, plan: plan, midi: prepared.midi)
        diagnostics.notice("Following started", time: clock())
        tracker.reset(notes: plan.notes, quarter: quarter(position))
        approvedWaits = Set(plan.waits.filter { seconds($0) < position - 1e-7 })
        tempo.reset(); audio.setRate(1)
        try enter(at: position, initial: true)
    }

    func stop() {
        if active { diagnostics.notice("Following stopped", time: clock()) }
        generation &+= 1; capture.release(); active = false; analyzing = false
        analyzer = nil; analysisOrigin = nil; analysisSamples = 0
        level = 0; lastPitch = nil; lastObservation = 0
        if let audio { audio.stop(); audio.setRate(1) }
        self.audio = nil; buffers = [:]; boundaries = []; queuedEnd = nil
    }

    private func seconds(_ quarter: Double) -> Double { prepared!.timing.prepSeconds + prepared!.midi.seconds(atQuarter: quarter) }
    private func quarter(_ seconds: Double) -> Double { prepared!.midi.quarter(atSeconds: seconds - prepared!.timing.prepSeconds) }

    private func enter(at location: Double, initial: Bool = false, fromAccompaniment: Bool = false) throws {
        guard let plan, let prepared, let audio else { return }
        position = location; entered = clock(); queuedEnd = nil
        if location >= prepared.end - 1e-7 {
            stop(); status = .finished; completed?(); return
        }
        let q = quarter(location)
        if let cadenza = plan.cadenzas.first(where: { abs($0.startQuarter - q) < 1e-7 }) {
            if !fromAccompaniment { audio.stop() }
            clearCadenzaAnalysis()
            phase = .cadenza(cadenza); status = .cadenza
            detail = "Right Arrow · orchestral entrance"; return
        }
        if let wait = plan.waits.first(where: { abs($0 - q) < 1e-7 && !approvedWaits.contains($0) }),
           !plan.cadenzas.contains(where: { q >= $0.startQuarter && q < $0.returnQuarter }) {
            audio.stop(); phase = .wait(wait); status = .waiting
            tracker.reset(notes: plan.notes, quarter: wait, preservingSound: true)
            detail = "Play the expected entrance · Right Arrow to continue"; return
        }
        if let free = plan.freePassages.first(where: { q >= $0.start - 1e-7 && q < $0.end - 1e-7 }) {
            if !fromAccompaniment { audio.stop() }
            tempo.reset(); phase = .free(free)
            let carriesPhrase = fromAccompaniment && entered - tracker.lastMatch < 0.4 &&
                tracker.index.map { plan.notes[$0].endQuarter >= q - 1e-7 && plan.notes[$0].startQuarter <= q + 1e-7 } == true
            if !carriesPhrase { tracker.reset(notes: plan.notes, quarter: q) }
            status = .following
            detail = "Solo passage · play freely · Right Arrow cues the return"; return
        }
        guard let buffer = buffers[location] else { throw MusicalError("Following playback boundary is unavailable. Reset and start again.") }
        phase = .audio; audioEnd = buffer.end
        try audio.play(buffer, immediate: !initial)
        status = .following; detail = "Following within ±\(Int(tolerance))%"
    }

    func cue() {
        guard active else { return }
        diagnostics.notice("Manual pedal cue", time: clock())
        do {
            switch phase {
            case .wait(let q):
                approvedWaits.insert(q); try enter(at: seconds(q))
            case .free(let range):
                try returnFromFree(range)
            case .cadenza(let passage):
                // All automatic behavior inside the manually controlled cadenza is skipped.
                clearCadenzaAnalysis()
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
        if let index = tracker.index, abs(plan!.notes[index].startQuarter - range.end) < 1e-7 {
            tracker.beginAccompaniedPhrase(scoreTime: prepared!.midi.seconds(atQuarter: range.end), tolerance: tolerance / 100)
        } else {
            tracker.reset(notes: plan!.notes, quarter: range.end)
        }
        try enter(at: seconds(range.end))
    }

    func tick() {
        guard active, let audio, let prepared, let plan else { return }
        let now = clock(), delta = min(0.1, max(0, now - max(entered, lastTick))); lastTick = now
        defer {
            if active {
                let atLimit: Bool
                if case .audio = phase { atLimit = tolerance > 0 && abs(tempo.rate - 1) >= tolerance / 100 - 0.002 }
                else { atLimit = false }
                diagnostics.monitor(status: status, time: now, atTempoLimit: atLimit)
            }
        }
        guard capture.ready else { inputFailed(); return }
        if case .cadenza = phase {
            // Keep the meter fresh without interpreting arbitrary cadenza notes.
            // Drain continuously so the pedal cannot release a backlog of old PCM.
            level = capture.storage?.peak.load(ordering: .relaxed) ?? 0
            _ = capture.storage?.stream?.drain()
            return
        }
        poll(now: now)
        do {
            switch phase {
            case .audio:
                position = min(audioEnd, audio.position(host: now))
                if position >= audioEnd - 1e-7 {
                    if let next = queuedEnd {
                        audioEnd = next; queuedEnd = nil
                    } else { try enter(at: audioEnd, fromAccompaniment: true) }
                    return
                }
                let q = quarter(position)
                guard q >= 0 else { return }
                let expectingSound = plan.notes.contains { $0.startQuarter <= q && q < $0.endQuarter }
                let age = now - tracker.lastMatch
                let input = FollowingTempoInput.accompanied(delta: delta, tolerance: tolerance / 100, tracker: tracker,
                    notes: plan.notes, midi: prepared.midi, scoreTime: position - prepared.timing.prepSeconds, time: now)
                let before = tempo
                let rate = tempo.update(input)
                audio.setRate(rate)
                let beatSeconds = prepared.midi.seconds(atQuarter: q + 0.001) - prepared.midi.seconds(atQuarter: q)
                diagnostics.recordControl(FollowingControlDecision(time: now, scoreTime: position - prepared.timing.prepSeconds,
                    plannedBPM: 0.06 / beatSeconds, before: before, input: input, rate: rate))
                if expectingSound && age > 1.5 && now - entered > 1.5 {
                    status = .lost; detail = "Keeping moving · listening for your position"
                } else if input.isHolding {
                    status = .holding; detail = "Listening for a steady phrase · within ±\(Int(tolerance))%"
                } else {
                    status = .following; detail = "Following within ±\(Int(tolerance))%"
                }
            case .wait:
                if now - lastObservation > 0.5 || (lastPitch != nil && now - entered > 0.7) { status = .lost }
            case .cadenza: break
            case .free(let range):
                if now - lastObservation > 0.5 { status = .lost; return }
                guard let index = tracker.index else {
                    if lastPitch != nil && now - entered > 0.4 { status = .lost }
                    return
                }
                let note = plan.notes[index]
                if note.startQuarter >= range.end - 1e-7 { try returnFromFree(range); return }
                let followingNote = index + 1 < plan.notes.count ? plan.notes[index + 1] : nil
                if now - tracker.lastMatch > 0.7 && lastPitch != nil { status = .lost }
                else if status != .lost || now - tracker.lastMatch < 0.3 {
                    // Allow the written rest and one beat of breathing room before
                    // treating silence in a recognized phrase as a deliberate pause.
                    let next = min(followingNote?.startQuarter ?? range.end, range.end)
                    let rest = max(0, seconds(next) - seconds(note.endQuarter))
                    let beat = seconds(next + 1) - seconds(next)
                    let paused = tracker.releasedAt.map { now - $0 > rest + beat } ?? false
                    status = lastPitch == nil && paused ? .waiting : .following
                }
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

    private func clearCadenzaAnalysis() {
        // Invalidate in-flight analysis as well as buffered input at both ends of
        // manual free time. A late result must not reset the indicator or steer
        // the newly cued orchestral return.
        generation &+= 1; analyzing = false
        analyzer = nil; analysisOrigin = nil; analysisSamples = 0
        lastPitch = nil; lastObservation = clock()
        _ = capture.storage?.stream?.drain()
        droppedSamples = capture.storage?.stream?.dropped.load(ordering: .acquiring) ?? 0
        diagnostics.audioDiscontinuity()
    }

    private func resetAnalysis() {
        diagnostics.preserveIncident("Audio delivery discontinuity", time: clock())
        diagnostics.audioDiscontinuity()
        diagnostics.notice("Audio delivery discontinuity; recognition timing reset", time: clock())
        analyzer = nil; analysisOrigin = nil; analysisSamples = 0; status = .lost
        // Keep sounding identity even immediately before a wait boundary:
        // discarding timing must never turn a held note into a new attack.
        if let plan { tracker.reset(notes: plan.notes, quarter: quarter(position), preservingSound: true) }
    }

    private func poll(now: Double) {
        guard let storage = capture.storage else { return }
        level = storage.peak.load(ordering: .relaxed)
        guard !analyzing, let stream = storage.stream else { return }
        let dropped = stream.dropped.load(ordering: .acquiring)
        let incoming = stream.drain()
        // Discontinuities invalidate both the sample clock and phrase timing.
        // Never let stale audio release a wait or cue an orchestral return.
        if dropped != droppedSamples || Double(incoming.count) / capture.sampleRate > 0.25 {
            droppedSamples = dropped; resetAnalysis()
            return
        }
        guard !incoming.isEmpty else { return }
        if let origin = analysisOrigin {
            let sampleEnd = origin + Double(analysisSamples + incoming.count) / capture.sampleRate
            // A missing delivery must not leave every later observation behind
            // the transport clock. Normal tap/UI scheduling jitter stays below
            // this allowance; accumulated contiguous batches retain their clock.
            if abs(now - sampleEnd) > 0.04 { resetAnalysis() }
        }
        if analyzer == nil {
            analyzer = SoloAudioAnalyzer(sampleRate: capture.sampleRate)
            analysisOrigin = now - Double(incoming.count) / capture.sampleRate
        }
        diagnostics.capture(incoming, start: analysisOrigin! + Double(analysisSamples) / capture.sampleRate)
        analysisSamples += incoming.count
        analyzing = true
        let processor = analyzer!, origin = analysisOrigin!, token = generation
        Task {
            let (updated, observations) = await Task.detached(priority: .userInitiated) {
                var updated = processor
                let observations = updated.process(incoming)
                return (updated, observations)
            }.value
            guard token == generation, active else { return }
            analyzing = false
            guard clock() - now < 0.25 else {
                resetAnalysis()
                return
            }
            analyzer = updated
            // Preserve every 10 ms observation, including multiple attacks in a
            // single tap delivery. Relative timing comes from samples, not UI polls.
            for observation in observations {
                guard active else { break }
                observe(pitch: observation.pitch, time: origin + observation.time,
                        rearticulated: observation.rearticulated)
            }
        }
    }

    func observe(pitch: Int?, time: Double, rearticulated: Bool = false) {
        guard active, let plan, let prepared else { return }
        lastPitch = pitch; lastObservation = time
        if case .cadenza = phase { return }
        let free: Bool, lastQuarter: Double
        switch phase {
        case .free(let range): free = true; lastQuarter = range.end
        case .wait(let entrance): free = true; lastQuarter = entrance
        default: free = false; lastQuarter = .infinity
        }
        let before = tracker
        let expected = quarter(position)
        let matched = tracker.observe(pitch: pitch, time: time, notes: plan.notes, expectedQuarter: quarter(position),
                                      free: free, midi: prepared.midi, rearticulated: rearticulated, throughQuarter: lastQuarter)
        diagnostics.record(FollowingDecision(tracker: before, pitch: pitch, time: time, expectedQuarter: expected,
                                             free: free, throughQuarter: lastQuarter, rearticulated: rearticulated,
                                             matched: matched, rate: tracker.rate, phase: String(describing: phase), level: level))
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
                    else { try enter(at: seconds(wait)); return }
                }
                if abs(q - range.end) < 1e-7 { try returnFromFree(range) }
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
    private func fail(_ error: Error) {
        diagnostics.notice(error.localizedDescription, time: clock())
        diagnostics.preserveIncident(error.localizedDescription, time: clock())
        stop(); status = .lost; detail = error.localizedDescription; failed?(detail)
    }
}
