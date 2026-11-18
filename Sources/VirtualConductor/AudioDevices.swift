import Foundation
import CoreAudio
import AVFoundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let input: Bool
    let output: Bool
}

enum NativeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// HAL reads only; never changes system defaults or device-wide settings.
final class AudioDevices {
    static func objectIDs(_ id: AudioObjectID, selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size)/MemoryLayout<AudioObjectID>.size)
        let result = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0.baseAddress!) }
        return result == noErr ? ids : []
    }
    static func nominalSampleRate(_ id: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = 0.0, size = UInt32(MemoryLayout<Double>.size)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        return rate
    }
    static func needsSeparateOutputUnit(_ id: AudioObjectID) -> Bool {
        // AVAudioEngine's hardware-format discovery loops on this mixed-width
        // aggregate (for example 2-channel headphones + BlackHole 16ch).
        let active = objectIDs(id, selector: kAudioAggregateDevicePropertyActiveSubDeviceList)
        guard !active.isEmpty else { return false }
        // With the headphones unplugged, only the loopback member remains.
        // AVAudioEngine can still hang discovering that aggregate’s format.
        var address = AudioObjectPropertyAddress(mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var members: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout.size(ofValue: members))
        if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &members) == noErr,
           let all = members?.takeRetainedValue(), CFArrayGetCount(all) > active.count { return true }
        let counts = active.map { channels($0, input: false) }.filter { $0 > 0 }
        return Set(counts).count > 1
    }
    static func outputPresentationLatency(_ id: AudioObjectID, sampleRate: Double) -> Double {
        func frames(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
            return value
        }
        let device = frames(id, kAudioDevicePropertyLatency, kAudioDevicePropertyScopeOutput)
        let streams = objectIDs(id, selector: kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        let stream = streams.map { frames($0, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal) }.max() ?? 0
        return (Double(device) + Double(stream)) / sampleRate
    }
    static func channels(_ id: AudioObjectID, input: Bool) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, memory) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    static func list() throws -> [AudioDevice] {
        try AudioHardwareSystem.shared.devices.map { device in
            try AudioDevice(id: device.id, uid: device.uid, name: device.name, input: channels(device.id, input: true) > 0, output: channels(device.id, input: false) > 0)
        }
    }
    static func defaultID(input: Bool) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout.size(ofValue: id))
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }
    static func bind(_ node: AVAudioIONode, device: AudioDeviceID) throws {
        try node.withAudioUnit { unit in
            guard let unit else { throw NativeError.message("Audio device unit unavailable.") }
            var id = device
            let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout.size(ofValue: id)))
            guard result == noErr else { throw NativeError.message("Could not select audio device (\(result)).") }
        }
    }
    static func boundID(_ node: AVAudioIONode) -> AudioDeviceID {
        node.withAudioUnit { unit in
            guard let unit else { return 0 }
            var id: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
            _ = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
            return id
        }
    }
}
