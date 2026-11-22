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
    private var accompanimentPositions = AccompanimentPositions()
    private var buffers: [Double: AudioSegment] = [:]
    private var boundaries: [Double] = []
    private var audioEnd = 0.0
    private var queuedEnd: Double?
    private var approvedWaits: Set<Double> = []
    private var phase: Phase = .audio
    private var lastTick = 0.0
    private var entered = 0.0
    private var listeningSince: Double?
    private var lastExpectedSound: Double?
    private static let trackingLossDelay = 1.5
    private var lastPitch: Int?
    private var lastObservation = 0.0
    private var droppedSamples = 0
    private var analyzer: SoloAudioAnalyzer?
    private var analysisSamples = 0
    private var analyzing = false
    private var generation: UInt64 = 0
    private(set) var lastFollowedBPM: Double?
    func clearLastFollowedTempo() { lastFollowedBPM = nil }
    var hasRecentPitchMatch: Bool { lastTick - tracker.lastMatch < FollowingTempo.recentMatchWindow }
    var completed: (() -> Void)?
    var failed: ((String) -> Void)?

    private enum Phase { case audio, wait(Double), free(PassageRange), cadenza(CompiledCadenza) }
    var canCue: Bool {
        guard active else { return false }
        if case .audio = phase { return false }
        return true
    }

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
        let timing = prepared.timing, midi = prepared.midi
        let points = plan.waits + plan.freePassages.flatMap { [$0.start, $0.end] } + plan.cadenzas.flatMap { [$0.startQuarter, $0.returnQuarter] }
        let beginsInFreeTime = plan.freePassages.contains { $0.start <= timing.startQuarter && timing.startQuarter < $0.end } ||
            plan.cadenzas.contains { $0.startQuarter <= timing.startQuarter && timing.startQuarter < $0.returnQuarter }
        let startBoundary = beginsInFreeTime ? [timing.prepSeconds] : []
        let limits = Array(Set([0, position, prepared.end] + startBoundary + points.filter { $0 >= timing.startQuarter }
            .map { timing.performanceTime(scoreSeconds: midi.seconds(atQuarter: $0)) }))
            .filter { $0 >= 0 && $0 <= prepared.end }.sorted()
        var releases = Dictionary(uniqueKeysWithValues: plan.freePassages.compactMap { gap -> (Double, Double)? in
            guard !plan.waits.contains(gap.start), !plan.cadenzas.contains(where: { $0.startQuarter == gap.start }) else { return nil }
            return (timing.performanceTime(scoreSeconds: midi.seconds(atQuarter: gap.start)), timing.performanceTime(scoreSeconds: midi.seconds(atQuarter: gap.end)))
        })
        for passage in plan.cadenzas {
            releases[timing.performanceTime(scoreSeconds: passage.startSeconds)] = PreparedPerformance.cadenzaReleaseEnd(passage, timing: timing)
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
        diagnostics.begin(sampleRate: capture.sampleRate, tolerance: tolerance, plan: plan, midi: prepared.practice.planned)
        diagnostics.notice("Following started", time: clock(), kind: .started)
        tracker.reset(notes: plan.notes, quarter: max(timing.startQuarter, quarter(position)))
        approvedWaits = Set(plan.waits.filter { $0 < timing.startQuarter || seconds($0) < position - 1e-7 })
        tempo.reset(); audio.setRate(1)
        try enter(at: position, initial: true)
    }

    func stop() {
        if active { diagnostics.notice("Following stopped", time: clock(), kind: .stopped) }
        generation &+= 1; capture.release(); active = false; analyzing = false
        analyzer = nil; analysisSamples = 0
        level = 0; lastPitch = nil; lastObservation = 0
        if let audio { audio.stop(); audio.setRate(1) }
        self.audio = nil; buffers = [:]; boundaries = []; queuedEnd = nil
    }

    private func seconds(_ quarter: Double) -> Double { prepared!.timing.performanceTime(scoreSeconds: prepared!.midi.seconds(atQuarter: quarter)) }
    private func quarter(_ seconds: Double) -> Double {
        let timing = prepared!.timing
        return prepared!.midi.quarter(atSeconds: timing.scoreTime(performanceSeconds: seconds))
    }

    private func enter(at location: Double, initial: Bool = false, fromAccompaniment: Bool = false) throws {
        guard let plan, let prepared, let audio else { return }
        position = location; entered = clock(); queuedEnd = nil
        accompanimentPositions = AccompanimentPositions()
        if location >= prepared.end - 1e-7 {
            stop(); status = .finished; completed?(); return
        }
        // Preparation may map near an earlier score passage. Only recognition
        // uses that score coordinate; transport enters waits/free time after it.
        let q = location < prepared.timing.prepSeconds ? -Double.infinity : quarter(location)
        if let cadenza = plan.cadenzas.first(where: { q >= $0.startQuarter - 1e-7 && q < $0.returnQuarter - 1e-7 }) {
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
            detail = plan.writtenCadenzas.contains(free)
                ? "Written cadenza · listening for the orchestral entrance"
                : "Solo passage · play freely · Right Arrow cues the return"
            return
        }
        guard let buffer = buffers[location] else { throw MusicalError("Following playback boundary is unavailable. Reset and start again.") }
        phase = .audio; audioEnd = buffer.end
        listeningSince = nil; lastExpectedSound = nil
        audio.setRate(prepared.practice.sourceRate(at: location) * tempo.rate)
        try audio.play(buffer, immediate: !initial)
        status = .following; detail = "Following within ±\(Int(tolerance))%"
    }

    func cue() {
        guard active else { return }
        diagnostics.notice("Manual pedal cue", time: clock(), kind: .manualCue)
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
            tracker.beginAccompaniedPhrase(scoreTime: prepared!.practice.planned.seconds(atQuarter: range.end), tolerance: tolerance / 100)
        } else {
            tracker.reset(notes: plan!.notes, quarter: range.end)
        }
        try enter(at: seconds(range.end))
    }

    func tick() {
        guard active, let audio, let prepared, let plan else { return }
        let now = clock(), delta = min(0.1, max(0, now - max(entered, lastTick))); lastTick = now
        var writtenRest = false
        defer {
            if active {
                let atLimit: Bool
                if case .audio = phase { atLimit = tolerance > 0 && abs(tempo.rate - 1) >= tolerance / 100 - 0.002 }
                else { atLimit = false }
                diagnostics.monitor(status: status, time: now, atTempoLimit: atLimit && !writtenRest)
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
                let baseRate = prepared.practice.sourceRate(at: position)
                guard position >= prepared.timing.prepSeconds else { audio.setRate(baseRate); return }
                let planned = prepared.practice.planned
                let q = quarter(position)
                if prepared.timing.scoreTime(performanceSeconds: position) - prepared.midi.seconds(atQuarter: q) > 1e-6 {
                    listeningSince = nil
                    writtenRest = true
                    accompanimentPositions = AccompanimentPositions()
                    audio.setRate(baseRate * tempo.rate)
                    status = .following; detail = "Caesura · waiting through the recorded pause"
                    return
                }
                let scoreTime = planned.seconds(atQuarter: q)
                accompanimentPositions.record(host: now, score: scoreTime)
                let expectingSound = plan.notes.contains { $0.startQuarter <= q && q < $0.endQuarter }
                writtenRest = !expectingSound
                if expectingSound {
                    if listeningSince == nil { listeningSince = now }
                    lastExpectedSound = now
                } else if let lastExpectedSound, now - lastExpectedSound >= Self.trackingLossDelay {
                    listeningSince = nil
                }
                let input = FollowingTempoInput.accompanied(delta: delta, tolerance: tolerance / 100, tracker: tracker,
                    notes: plan.notes, midi: planned, scoreTime: scoreTime, time: now)
                let before = tempo
                let rate = tempo.update(input)
                audio.setRate(baseRate * rate)
                let bpm = prepared.practice.bpm(atQuarter: q)
                if expectingSound && input.isFollowingTempo { lastFollowedBPM = bpm * rate }
                diagnostics.recordControl(FollowingControlDecision(time: now, scoreTime: scoreTime,
                    plannedBPM: bpm, before: before, input: input, rate: rate))
                if expectingSound, let listeningSince, now - max(listeningSince, tracker.lastMatch) > Self.trackingLossDelay {
                    status = .lost; detail = "Keeping moving · listening for your position"
                } else if writtenRest {
                    status = .following; detail = "Written solo rest · keeping the pulse"
                } else if input.isCorrectingPosition {
                    status = .following; detail = "Aligning with your note attacks"
                } else if input.isHolding {
                    status = .holding
                    detail = hasRecentPitchMatch ? "Matching your notes · keeping the current tempo" : "Listening for your next matching note"
                } else {
                    status = .following; detail = "Following within ±\(Int(tolerance))%"
                }
            case .wait:
                if tracker.isPlayingGrace(at: now), now - lastObservation <= 0.5 { status = .waiting }
                else if now - lastObservation > 0.5 || (lastPitch != nil && now - entered > 0.7) { status = .lost }
            case .cadenza: break
            case .free(let range):
                let planned = prepared.practice.planned
                if now - lastObservation > 0.5 {
                    status = .lost; detail = "Waiting for microphone audio · Right Arrow cues the return"
                    return
                }
                guard let index = tracker.index else {
                    if lastPitch != nil && now - entered > 0.4 {
                        status = .lost; detail = "Listening for matching notes · Right Arrow cues the return"
                    } else if now - entered > 1.5 {
                        status = .lost; detail = "No clear pitch · check microphone and gain · Right Arrow cues the return"
                    }
                    return
                }
                let note = plan.notes[index]
                if note.startQuarter >= range.end - 1e-7 { try returnFromFree(range); return }
                let followingNote = index + 1 < plan.notes.count ? plan.notes[index + 1] : nil
                if now - tracker.lastMatch > 0.7 && lastPitch != nil {
                    status = .lost; detail = "Listening for matching notes · Right Arrow cues the return"
                }
                else if status != .lost || now - tracker.lastMatch < 0.3 {
                    // Allow the written rest and one beat of breathing room before
                    // treating silence in a recognized phrase as a deliberate pause.
                    let next = min(followingNote?.startQuarter ?? range.end, range.end)
                    let rest = max(0, planned.seconds(atQuarter: next) - planned.seconds(atQuarter: note.endQuarter))
                    let beat = planned.seconds(atQuarter: next + 1) - planned.seconds(atQuarter: next)
                    let paused = tracker.releasedAt.map { now - $0 > rest + beat } ?? false
                    status = lastPitch == nil && paused ? .waiting : .following
                }
                if status == .lost { return }
                detail = "Following your solo · Right Arrow cues the return"
                let first = max(prepared.timing.prepSeconds, seconds(range.start))
                let playedTime = planned.seconds(atQuarter: note.startQuarter) + max(0, now - tracker.lastAttack) * tracker.rate
                let playedPosition = seconds(planned.quarter(atSeconds: playedTime))
                if note.endQuarter > range.end + 1e-7 {
                    position = max(first, min(seconds(range.end), playedPosition))
                    status = .waiting; detail = "Held note crosses the orchestral return · use Right Arrow"
                    return
                }
                position = max(first, min(seconds(min(note.endQuarter, range.end)), playedPosition))
                if let release = tracker.releasedAt {
                    let next = min(range.end, followingNote?.startQuarter ?? range.end)
                    position = max(first, min(seconds(next), seconds(planned.quarter(atSeconds: planned.seconds(atQuarter: note.endQuarter) + max(0, now - release)))))
                    let needsReturnAttack = followingNote.map { abs($0.startQuarter - range.end) < 1e-7 } ?? false
                    if !needsReturnAttack, next >= range.end, now - release >= max(0, planned.seconds(atQuarter: range.end) - planned.seconds(atQuarter: note.endQuarter)) {
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
        analyzer = nil; analysisSamples = 0
        lastPitch = nil; lastObservation = clock()
        _ = capture.storage?.stream?.drain()
        droppedSamples = capture.storage?.stream?.dropped.load(ordering: .acquiring) ?? 0
        diagnostics.audioDiscontinuity()
    }

    private func resetAnalysis(_ reason: String) {
        accompanimentPositions = AccompanimentPositions()
        let now = clock()
        diagnostics.notice("Audio delivery discontinuity: " + reason, time: now, kind: .interruption)
        diagnostics.preserveIncident(reason, time: now)
        diagnostics.audioDiscontinuity()
        analyzer = nil; analysisSamples = 0; status = .lost
        // Keep sounding identity even immediately before a wait boundary:
        // discarding timing must never turn a held note into a new attack.
        if let plan, let prepared { tracker.reset(notes: plan.notes, quarter: max(prepared.timing.startQuarter, quarter(position)), preservingSound: true) }
    }

    private func poll(now: Double) {
        guard let storage = capture.storage else { return }
        level = storage.peak.load(ordering: .relaxed)
        guard !analyzing, let stream = storage.stream else { return }
        let dropped = stream.dropped.load(ordering: .acquiring)
        let batch = stream.drain()
        if dropped != droppedSamples {
            droppedSamples = dropped; resetAnalysis("Microphone sample queue overflowed")
            return
        }
        guard let batch else { return }
        let incoming = batch.samples
        let duration = Double(incoming.count) / capture.sampleRate
        let sampleEnd = batch.start + duration
        guard duration <= 0.25, abs(now - sampleEnd) <= 0.25 else {
            resetAnalysis("Microphone audio was stale or backlogged")
            return
        }
        if batch.followsGap { resetAnalysis("Gap in microphone timestamps") }
        let returnCue: (preceding: Int, entrance: Int)?
        if case .free(let range) = phase, let plan, let index = tracker.index,
           index + 1 < plan.notes.count, abs(plan.notes[index + 1].startQuarter - range.end) < 1e-7 {
            returnCue = (plan.notes[index].pitch, plan.notes[index + 1].pitch)
        } else {
            returnCue = nil
        }
        let processor = analyzer ?? SoloAudioAnalyzer(sampleRate: capture.sampleRate)
        // The analyzer counts samples across calls. Map this batch onto the
        // microphone clock even if its delivery or the UI tick ran late.
        let origin = batch.start - Double(analysisSamples) / capture.sampleRate
        diagnostics.capture(incoming, start: batch.start)
        analysisSamples += incoming.count
        analyzing = true
        let token = generation
        Task {
            let (updated, observations) = await Task.detached(priority: .userInitiated) {
                var updated = processor
                let observations = updated.process(incoming, returnCue: returnCue)
                return (updated, observations)
            }.value
            guard token == generation, active else { return }
            analyzing = false
            guard clock() - sampleEnd < 0.25 else {
                resetAnalysis("Microphone analysis arrived late")
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
        let matched = tracker.observe(pitch: pitch, time: time, notes: plan.notes, expectedQuarter: expected,
                                      free: free, midi: prepared.practice.planned, rearticulated: rearticulated,
                                      throughQuarter: lastQuarter, accompanimentAtOnset: accompanimentPositions.scoreTime)
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
        diagnostics.notice(error.localizedDescription, time: clock(), kind: .interruption)
        diagnostics.preserveIncident(error.localizedDescription, time: clock())
        stop(); status = .lost; detail = error.localizedDescription; failed?(detail)
    }
}
