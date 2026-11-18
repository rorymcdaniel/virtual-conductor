import AVFoundation
import ConductorCore

/// All frame indices are in the decoded WAV's sample rate. Host seconds use mach time.
struct AudioSegment {
    let position: Double // performance seconds, includes preparation
    let end: Double
    let music: AVAudioPCMBuffer
    let clicks: AVAudioPCMBuffer
}
final class PreparedPerformance {
    let midi: MIDIFile
    let timing: PerformanceTiming
    var practice: PracticeTempo
    let source: AVAudioPCMBuffer
    let passages: [CompiledCadenza]
    let segments: [AudioSegment]
    var duration: Double { Double(source.frameLength) / source.format.sampleRate }
    var end: Double { timing.performanceTime(scoreSeconds: max(duration, midi.duration)) }
    init(midi: MIDIFile, source: AVAudioPCMBuffer, preparation: Int, passages: [CadenzaPassage], startMeasure: Int = 1, tempoMarks: [PracticeTempoMark] = [], tempoBoundaries: Set<Double>? = nil, deletedTempos: Set<Double> = []) throws {
        self.midi = midi; self.source = source
        let timing = try PerformanceTiming(midi: midi, preparatoryMeasures: preparation, startMeasure: startMeasure)
        self.timing = timing
        practice = try PracticeTempo(timing: timing, marks: tempoMarks, boundaries: tempoBoundaries ?? midi.practiceTempoBoundaries(score: nil), deleted: deletedTempos)
        let compiled = try compileCadenzas(passages, midi: midi, audioDuration: Double(source.frameLength) / source.format.sampleRate)
            .filter { $0.returnQuarter > timing.startQuarter }
        self.passages = compiled
        let end = timing.performanceTime(scoreSeconds: max(Double(source.frameLength) / source.format.sampleRate, midi.duration))
        let starts = [0.0] + compiled.map { timing.performanceTime(scoreSeconds: $0.returnSeconds) }
        let ends = compiled.map { max(timing.prepSeconds, timing.performanceTime(scoreSeconds: $0.startSeconds)) } + [end]
        segments = try zip(starts, ends).enumerated().map { index, bounds in
            let release = index < compiled.count && compiled[index].startQuarter >= timing.startQuarter
                ? Self.cadenzaReleaseEnd(compiled[index], timing: timing) : nil
            return try Self.makeSegment(source: source, timing: timing, position: bounds.0, end: bounds.1, ringOutUntil: release)
        }
    }
    /// A cadenza may be placed in sounding audio: never play arbitrarily far into
    /// the skipped passage when no quiet gap can be found.
    static func cadenzaReleaseEnd(_ passage: CompiledCadenza, timing: PerformanceTiming) -> Double {
        timing.performanceTime(scoreSeconds: min(passage.returnSeconds, passage.startSeconds + 3))
    }
    static func load(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.length < Int64(UInt32.max), let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw NativeError.message("The WAV is empty or too long.") }
        try file.read(into: buffer)
        guard buffer.floatChannelData != nil else { throw NativeError.message("The WAV could not be decoded as PCM.") }
        return buffer
    }
    static func makeSegment(source: AVAudioPCMBuffer, timing: PerformanceTiming, position: Double, end: Double, ringOutUntil: Double? = nil) throws -> AudioSegment {
        let rate = source.format.sampleRate
        // A single rounding function is used for boundaries and source offsets.
        let first = Int64((position * rate).rounded()), last = Int64((end * rate).rounded())
        let count = max(1, last - first)
        let prepFrame = Int64((timing.prepSeconds * rate).rounded())
        let sourceOrigin = prepFrame - Int64((timing.startSeconds * rate).rounded())
        let musicStart = max(Int64((timing.leadSeconds * rate).rounded()), sourceOrigin)
        var musicEnd = last
        if let limit = ringOutUntil, last >= prepFrame {
            // Continue the rendered release into a notated rest. Stop looking at the
            // first 50 ms of quiet, or the next orchestral entrance, whichever is first.
            let limitFrame = min(Int64((limit * rate).rounded()), sourceOrigin + Int64(source.frameLength))
            var quietFrames = 0
            while musicEnd < limitFrame {
                let offset = Int(musicEnd - sourceOrigin)
                let audible = (0..<Int(source.format.channelCount)).contains { abs(source.floatChannelData![$0][offset]) > 0.0001 }
                quietFrames = audible ? 0 : quietFrames + 1
                musicEnd += 1
                if quietFrames >= Int(rate * 0.05) { break }
            }
        }
        let musicCount = max(count, musicEnd - first)
        guard musicCount < Int64(UInt32.max), let music = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: UInt32(musicCount)), let clickFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1), let clicks = AVAudioPCMBuffer(pcmFormat: clickFormat, frameCapacity: UInt32(count)) else { throw NativeError.message("Could not prepare audio buffers.") }
        music.frameLength = UInt32(musicCount); clicks.frameLength = UInt32(count)
        for c in 0..<Int(source.format.channelCount) {
            let dest = music.floatChannelData![c]; dest.initialize(repeating: 0, count: Int(musicCount))
            // Sound the preceding measures during preparation. Only the upbeat
            // and any count-in before the score's beginning remain silent.
            let from = max(first, musicStart), to = min(musicEnd, sourceOrigin + Int64(source.frameLength))
            if to > from { dest.advanced(by: Int(from-first)).update(from: source.floatChannelData![c].advanced(by: Int(from-sourceOrigin)), count: Int(to-from)) }
        }
        // Smooth the end of a release even when the safety limit, rather than
        // silence, ended it. The logical cutoff and click buffer stay unchanged.
        if musicEnd > last {
            let fadeFrames = min(Int(rate * 0.01), Int(musicEnd - last))
            for c in 0..<Int(source.format.channelCount) {
                for i in 0..<fadeFrames {
                    music.floatChannelData![c][Int(musicCount) - fadeFrames + i] *= Float(fadeFrames - 1 - i) / Float(max(1, fadeFrames - 1))
                }
            }
        }
        let dest = clicks.floatChannelData![0]; dest.initialize(repeating: 0, count: Int(count))
        for beat in 0..<timing.totalBeats {
            let seconds = timing.beatTime(beat)
            guard seconds >= position-1e-8, seconds < end else { continue }
            let offset = Int((seconds*rate).rounded()-Double(first))
            let length = min(Int(rate * 0.04), Int(count)-offset)
            guard offset >= 0, length > 0 else { continue }
            for i in 0..<length {
                let t = Double(i)/rate
                let gain = t < 0.002 ? 0.0001 * pow(600, t/0.002) : 0.06 * pow(0.0001/0.06, min(1,(t-0.002)/0.033))
                dest[offset+i] = Float(sin(2 * .pi * (beat%4 == 0 ? 1000 : 750) * t) * gain)
            }
        }
        return AudioSegment(position: position, end: end, music: music, clicks: clicks)
    }
    func sounding(_ values: [CompiledCadenza]) -> [CompiledCadenza] {
        let rate = source.format.sampleRate, window = max(1, Int((rate*0.01).rounded()))
        return values.filter { p in
            let start = max(0,Int(ceil(p.startSeconds*rate))), end = min(Int(source.frameLength),Int(ceil(p.returnSeconds*rate)))
            for c in 0..<Int(source.format.channelCount) {
                let data = source.floatChannelData![c]
                for first in stride(from:start,to:end,by:window) {
                    let last = min(end,first+window); var power = 0.0
                    for i in first..<last { power += Double(data[i])*Double(data[i]) }
                    if power/Double(last-first) >= 1e-6 { return true }
                }
            }
            return false
        }
    }
}

/// Control-side playback. Mixed-channel aggregates use a small realtime output
/// adapter; score, UI and transport decisions stay outside the render callback.
@MainActor final class PerformanceAudio {
    private(set) var engine = AVAudioEngine()
    private var music = AVAudioPlayerNode()
    private var clicks = AVAudioPlayerNode()
    private var auxiliary = AVAudioPlayerNode()
    private var performanceMixer = AVAudioMixerNode()
    private var timePitch = AVAudioUnitTimePitch()
    private var clockHost = 0.0
    private var clockPosition = 0.0
    private(set) var playbackRate = 1.0
    private(set) var device: AudioDevice?
    private(set) var audibleOrigin = 0.0
    private(set) var auxiliaryOrigin = 0.0
    var volume: Float = 0.7 { didSet { engine.mainMixerNode.outputVolume = volume } }
    var clicksEnabled = false { didSet { clicks.volume = clicksEnabled ? 1 : 0 } }
    var interrupted: (() -> Void)?
    private var notification: NSObjectProtocol?
    private var format: AVAudioFormat?
    private var configuration: UInt64 = 0
    private var hardwareOutput: HardwareOutput?
    var renderDelay: Double { hardwareOutput?.renderDelay ?? 0 }
    var boundOutputID: AudioDeviceID { hardwareOutput?.unit.deviceID ?? AudioDevices.boundID(engine.outputNode) }
    private var outputLatency: Double { hardwareOutput?.presentationLatency ?? engine.outputNode.presentationLatency }
    nonisolated static var hostSeconds: Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
    func configure(device: AudioDevice, format: AVAudioFormat) throws {
        shutdown()
        var configured = false
        defer { if !configured { shutdown() } }
        engine = AVAudioEngine(); music = AVAudioPlayerNode(); clicks = AVAudioPlayerNode(); auxiliary = AVAudioPlayerNode()
        performanceMixer = AVAudioMixerNode(); timePitch = AVAudioUnitTimePitch()
        if AudioDevices.needsSeparateOutputUnit(device.id) {
            hardwareOutput = try HardwareOutput(device: device)
            try hardwareOutput!.prepare(engine: engine)
        } else {
            try AudioDevices.bind(engine.outputNode, device: device.id)
        }
        engine.attach(music); engine.attach(clicks); engine.attach(auxiliary)
        engine.attach(performanceMixer); engine.attach(timePitch)
        try engine.connectNode(music, to: performanceMixer, format: format)
        try engine.connectNode(clicks, to: performanceMixer, format: AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1))
        try engine.connectNode(performanceMixer, to: timePitch, format: format)
        try engine.connectNode(timePitch, to: engine.mainMixerNode, format: format)
        try engine.connectNode(auxiliary, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1))
        self.device = device; self.format = format
        engine.mainMixerNode.outputVolume = volume; clicks.volume = clicksEnabled ? 1 : 0
        engine.prepare(); try engine.start(); try hardwareOutput?.start()
        guard boundOutputID == device.id else { throw NativeError.message("Output binding changed unexpectedly. Select an output again.") }
        let identity = configuration
        notification = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in Task { @MainActor in guard let self, self.configuration == identity else { return }; self.interrupted?() } }
        configured = true
    }
    var ready: Bool { engine.isRunning && device != nil && (hardwareOutput?.ready ?? (boundOutputID == device?.id)) }
    func play(_ segment: AudioSegment, immediate: Bool) throws {
        guard ready else { throw NativeError.message("Output interrupted. Select an output and supply a fresh cue.") }
        stop()
        hardwareOutput?.hold()
        // A fresh start/resume must not inherit time-stretch buffering from the
        // previous phrase. Adjacent appended buffers still remain continuous.
        timePitch.reset()
        // Returns use now, with no startup lead. Preparation/pause starts retain the browser's 200 ms lead.
        let host = Self.hostSeconds + (immediate ? 0 : 0.2)
        let at = hardwareOutput == nil ? AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: host)) : nil
        music.scheduleBuffer(segment.music, at: nil)
        clicks.scheduleBuffer(segment.clicks, at: nil)
        do {
            try music.playAudio(at: at)
            try clicks.playAudio(at: at)
            hardwareOutput?.resume(at: host)
        } catch {
            stop()
            hardwareOutput?.resume(at: Self.hostSeconds)
            throw error
        }
        // presentationLatency includes downstream output latency; never add device latency again.
        audibleOrigin = host + outputLatency - segment.position
        clockHost = host + outputLatency + timePitch.latency
        clockPosition = segment.position
        audibleOrigin += timePitch.latency
    }
    func position(host: Double = PerformanceAudio.hostSeconds) -> Double {
        clockPosition + max(0, host - clockHost) * playbackRate
    }
    func setRate(_ rate: Double) {
        let now = Self.hostSeconds
        clockPosition = position(host: now); clockHost = max(now, clockHost)
        // The practice pace and the following adjustment multiply. Use the
        // time-pitch unit’s supported range for their combined source rate.
        playbackRate = min(32, max(1.0 / 32, rate)); timePitch.rate = Float(playbackRate)
    }
    /// Appending an already prepared adjacent buffer preserves continuous rendering.
    func append(_ segment: AudioSegment) {
        music.scheduleBuffer(segment.music, at: nil)
        clicks.scheduleBuffer(segment.clicks, at: nil)
    }
    func stop() {
        music.stop(); clicks.stop(); auxiliary.stop()
        hardwareOutput?.resume(at: Self.hostSeconds)
    }
    func shutdown() {
        configuration &+= 1
        if let notification { NotificationCenter.default.removeObserver(notification) }; notification = nil
        hardwareOutput?.stop(); hardwareOutput = nil
        stop(); engine.stop(); device = nil
    }
    func playTake(samples: [Float], sampleRate: Double) throws {
        guard ready, let target = format else { throw NativeError.message("Select an available output before playing the take.") }
        stop()
        // Resample off the audio callback; input/output rates and devices remain independent.
        let count = max(1, Int(Double(samples.count)*target.sampleRate/sampleRate))
        let mono = AVAudioFormat(standardFormatWithSampleRate: target.sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: UInt32(count))!; buffer.frameLength = UInt32(count)
        for i in 0..<count {
            let x = Double(i)*sampleRate/target.sampleRate, a = min(samples.count-1,Int(x)), b = min(samples.count-1,a+1)
            buffer.floatChannelData![0][i] = samples[a] + Float(x-Double(a))*(samples[b]-samples[a])
        }
        auxiliary.scheduleBuffer(buffer, at: nil); try auxiliary.playAudio()
        auxiliaryOrigin = Self.hostSeconds + outputLatency
    }
    func testTone() throws {
        let rate = format?.sampleRate ?? 44100
        var samples = [Float](repeating: 0, count: Int(rate * 0.3))
        for i in samples.indices {
            let wave = sin(Double(i) / rate * 2 * Double.pi * 440)
            let envelope = min(1.0, Double(i) / 100) * min(1.0, Double(samples.count-i) / 300)
            samples[i] = Float(wave * 0.05 * envelope)
        }
        try playTake(samples: samples, sampleRate: rate)
    }
}
