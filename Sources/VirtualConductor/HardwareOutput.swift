import AVFoundation
import CoreAudio
import Synchronization

/// Player sample clocks change with time stretching. Gate the hardware render
/// instead, so a future start keeps its wall-clock delay at every playback rate.
final class OutputRenderStart: Sendable {
    let failed = Atomic<Bool>(false)
    let host = Atomic<UInt64>(0)
    let deferredFrames = Atomic<Int>(0)
}

/// Drives the existing playback graph through a HAL output unit, bypassing
/// AVAudioEngine's mixed-channel aggregate format-discovery loop. This never
/// changes system defaults, aggregate membership, or device sample rates.
@MainActor final class HardwareOutput {
    let unit: AUAudioUnit
    let format: AVAudioFormat
    private let renderStart = OutputRenderStart()
    private var silence: AVAudioPCMBuffer?
    private let deviceID: AudioDeviceID
    private let subdevices: [AudioObjectID]

    init(device: AudioDevice) throws {
        deviceID = device.id
        let rate = AudioDevices.nominalSampleRate(device.id)
        guard rate.isFinite, (8000...384000).contains(rate),
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            throw NativeError.message("The selected output has no usable audio format.")
        }
        self.format = format
        subdevices = AudioDevices.objectIDs(device.id, selector: kAudioAggregateDevicePropertyActiveSubDeviceList)
        unit = try AUAudioUnit(componentDescription: AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0))
        try unit.setDeviceID(device.id)
        try unit.inputBusses[0].setFormat(format)
        unit.maximumFramesToRender = 4096
    }

    func prepare(engine: AVAudioEngine) throws {
        try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: unit.maximumFramesToRender)
        let render = engine.manualRenderingBlock, start = renderStart
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: unit.maximumFramesToRender)!
        silence.frameLength = silence.frameCapacity
        for channel in 0..<Int(format.channelCount) {
            silence.floatChannelData![channel].initialize(repeating: 0, count: Int(silence.frameLength))
        }
        self.silence = silence
        let silentBuffers = UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList)
        unit.outputProvider = { _, timestamp, frames, _, buffers in
            func clear() {
                let output = UnsafeMutableAudioBufferListPointer(buffers)
                for i in output.indices {
                    let bytes = Int(frames) * MemoryLayout<Float>.size
                    if output[i].mData == nil { output[i].mData = silentBuffers[i].mData }
                    if let data = output[i].mData { memset(data, 0, bytes) }
                    output[i].mDataByteSize = UInt32(bytes)
                }
            }
            guard timestamp.pointee.mHostTime >= start.host.load(ordering: .acquiring) else {
                clear(); return noErr
            }
            var error: OSStatus = 0
            let result = render(frames, buffers, &error)
            if result != .success {
                clear()
                if result == .cannotDoInCurrentContext { start.deferredFrames.wrappingAdd(Int(frames), ordering: .relaxed) }
                if result == .error { start.failed.store(true, ordering: .releasing) }
            }
            return noErr
        }
        try unit.allocateRenderResources()
    }

    func start() throws { try unit.startHardware() }
    func hold() { renderStart.host.store(UInt64.max, ordering: .releasing) }
    func resume(at host: Double) { renderStart.host.store(AVAudioTime.hostTime(forSeconds: host), ordering: .releasing) }
    func stop() {
        unit.stopHardware(); unit.outputProvider = nil
        if unit.renderResourcesAllocated { unit.deallocateRenderResources() }
        silence = nil
    }
    var ready: Bool {
        unit.isRunning && unit.deviceID == deviceID && !renderStart.failed.load(ordering: .acquiring) &&
        AudioDevices.nominalSampleRate(deviceID) == format.sampleRate &&
        AudioDevices.objectIDs(deviceID, selector: kAudioAggregateDevicePropertyActiveSubDeviceList) == subdevices
    }
    var presentationLatency: Double { AudioDevices.outputPresentationLatency(deviceID, sampleRate: format.sampleRate) }
    var renderDelay: Double { Double(renderStart.deferredFrames.load(ordering: .relaxed)) / format.sampleRate }
}
