import AVFoundation
import Synchronization

/// One producer (audio tap), one control consumer after stopping the engine.
/// Preallocated storage and atomics keep allocation and locks out of the tap.
final class CaptureStorage: @unchecked Sendable {
    let samples: UnsafeMutablePointer<Float>
    let capacity: Int
    let count = Atomic<Int>(0)
    let receivedFrames = Atomic<Int>(0)
    let recording = Atomic<Bool>(false)
    let peak = Atomic<Float>(0)
    let receiving = Atomic<Bool>(false)
    let stream: LiveSampleBuffer?
    init(rate: Double, streaming: Bool = false) {
        stream = streaming ? LiveSampleBuffer() : nil
        capacity = streaming ? 1 : Int(rate * 120)
        samples = .allocate(capacity:capacity); samples.initialize(repeating:0,count:capacity)
    }
    deinit { samples.deallocate() }
    func receive(_ buffer: AVReadOnlyAudioPCMBuffer) {
        receiving.store(true,ordering:.releasing)
        defer { receiving.store(false,ordering:.releasing) }
        guard buffer.format.commonFormat == .pcmFormatFloat32 else { return }
        receivedFrames.store(receivedFrames.load(ordering:.relaxed) + Int(buffer.frameLength),ordering:.releasing)
        let size = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
        var maximum: Float = 0
        let capturing = recording.load(ordering:.acquiring)
        var offset = count.load(ordering:.relaxed)
        for i in 0..<size {
            var value: Float = 0
            for c in 0..<channelCount {
                if case .float(let channel) = buffer.channelData(c) { value += channel[i * buffer.stride] }
            }
            value /= Float(channelCount); maximum = max(maximum,abs(value))
            stream?.write(value)
            if capturing && offset < capacity { samples[offset] = value; offset += 1 }
        }
        if capturing { count.store(offset,ordering:.releasing) }
        peak.store(maximum,ordering:.relaxed)
    }
}
@MainActor final class InputCapture {
    private var engine: AVAudioEngine?
    private(set) var storage: CaptureStorage?
    private(set) var sampleRate: Double = 0
    private var observer: NSObjectProtocol?
    private var configuration: UInt64 = 0
    var interrupted: (() -> Void)?
    func enable(device: UInt32, streaming: Bool = false) throws {
        release()
        let engine = AVAudioEngine()
        try AudioDevices.bind(engine.inputNode, device:device)
        let format = engine.inputNode.outputFormat(forBus:0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NativeError.message("The selected device has no usable input.") }
        let storage = CaptureStorage(rate:format.sampleRate, streaming: streaming)
        try engine.inputNode.installAudioTap(onBus:0,bufferSize:1024,format:format) { buffer, _ in storage.receive(buffer) }
        // No connection from the microphone to the output mixer: no monitoring.
        engine.prepare()
        do { try engine.start() } catch { engine.inputNode.removeTap(onBus:0); throw error }
        guard AudioDevices.boundID(engine.inputNode) == device else { engine.stop(); engine.inputNode.removeTap(onBus:0); throw NativeError.message("Input device changed unexpectedly.") }
        self.engine = engine; self.storage = storage; sampleRate = format.sampleRate
        let identity = configuration
        observer = NotificationCenter.default.addObserver(forName:.AVAudioEngineConfigurationChange,object:engine,queue:nil) { [weak self] _ in Task { @MainActor in guard let self, self.configuration == identity else { return }; self.interrupted?() } }
    }
    var ready: Bool { engine?.isRunning == true }
    func start() throws {
        guard ready, let storage else { throw NativeError.message("Enable the input first.") }
        storage.count.store(0,ordering:.releasing)
        storage.recording.store(true,ordering:.releasing)
    }
    func finish() -> (CaptureStorage,Double)? {
        guard let storage else { return nil }
        // Stop before consuming storage; a tap already in flight may finish its final block.
        engine?.stop()
        storage.recording.store(false,ordering:.releasing)
        let result = (storage,sampleRate)
        release(); return result
    }
    func release() {
        configuration &+= 1
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        if let engine { engine.stop(); if engine.inputNode.numberOfOutputs > 0 { engine.inputNode.removeTap(onBus:0) } }
        engine = nil; storage = nil
    }
}
