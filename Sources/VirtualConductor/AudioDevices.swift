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
