import Foundation
import CoreAudio

public enum BudsAudio {
    public struct State: Equatable, Sendable {
        public let selected: Bool
        public let playing: Bool
    }
    private static func property(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var key = property(selector), size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(device, &key, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
    private static func scalar(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var key = property(selector), size = UInt32(MemoryLayout<UInt32>.size), result: UInt32 = 0
        guard AudioObjectGetPropertyData(device, &key, 0, nil, &size, &result) == noErr else { return 0 }
        return result
    }
    private static func normalized(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
    /// Activity on the current default output, including the built-in speakers
    /// while the Buds are disconnected. No audio content is captured.
    public static func defaultOutputIsPlaying() -> Bool {
        var key = property(kAudioHardwarePropertyDefaultOutputDevice), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var device: AudioDeviceID = 0
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &key, 0, nil, &size, &device) == noErr, device != 0 else { return false }
        return scalar(device, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0
    }

    private static func matchingOutput(address: String, name: String) throws -> AudioDeviceID? {
        var key = property(kAudioHardwarePropertyDevices), size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &key, 0, nil, &size) == noErr else { throw ContinuityError.message("Could not enumerate Mac audio outputs.") }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !devices.isEmpty else { return nil }
        let read = devices.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &key, 0, nil, &size, $0.baseAddress!) }
        guard read == noErr else { throw ContinuityError.message("Could not read Mac audio outputs.") }
        let wanted = normalized(address)
        var matches: [AudioDeviceID] = []
        for device in devices {
            let transport = scalar(device, kAudioDevicePropertyTransportType)
            guard transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
                  scalar(device, kAudioDevicePropertyDeviceIsAlive) != 0 else { continue }
            let uid = normalized(string(device, kAudioDevicePropertyDeviceUID) ?? "")
            let deviceName = string(device, kAudioObjectPropertyName) ?? ""
            guard (!wanted.isEmpty && uid.contains(wanted)) || deviceName.caseInsensitiveCompare(name) == .orderedSame else { continue }
            var outputKey = property(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput), outputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &outputKey, 0, nil, &outputSize) == noErr, outputSize > 0 else { continue }
            matches.append(device)
        }
        return matches.first
    }
    public static func state(address: String, name: String) throws -> State {
        guard let device = try matchingOutput(address: address, name: name) else { return .init(selected: false, playing: false) }
        var key = property(kAudioHardwarePropertyDefaultOutputDevice), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var selected: AudioDeviceID = 0
        let result = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &key, 0, nil, &size, &selected)
        guard result == noErr else { throw ContinuityError.message("Could not read the current Mac audio output.") }
        return .init(selected: selected == device, playing: scalar(device, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0)
    }
    /// Select only a live Bluetooth output matching the user's chosen paired Buds.
    public static func selectOutput(address: String, name: String) throws -> Bool {
        guard let selected = try matchingOutput(address: address, name: name) else { return false }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var output = selected, key = property(kAudioHardwarePropertyDefaultOutputDevice), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let result = AudioObjectSetPropertyData(system, &key, 0, nil, size, &output)
        guard result == noErr else { throw ContinuityError.message("macOS could not select the Buds audio output (\(result)).") }
        var actual: AudioDeviceID = 0
        guard AudioObjectGetPropertyData(system, &key, 0, nil, &size, &actual) == noErr, actual == selected else {
            throw ContinuityError.message("macOS did not keep the selected Buds audio output.")
        }
        return true
    }
}
