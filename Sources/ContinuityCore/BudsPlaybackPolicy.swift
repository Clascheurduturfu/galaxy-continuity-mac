import Foundation
import CoreAudio
import Darwin

/// Process metadata only. No taps, audio samples, recording permission or history.
public struct BudsAudioProcess: Equatable, Sendable {
    public let objectID: UInt32
    public let bundleID: String?
    public let processName: String?
    public let runningOutput: Bool
    public let devices: [UInt32]
    public init(objectID: UInt32, bundleID: String?, processName: String?, runningOutput: Bool, devices: [UInt32]) {
        self.objectID = objectID; self.bundleID = bundleID; self.processName = processName
        self.runningOutput = runningOutput; self.devices = devices
    }
}

public enum BudsPlaybackPolicy {
    private static let systemBundles: Set<String> = [
        "com.apple.audio.systemsoundserver", "com.apple.systemsoundserverd", "com.apple.soundserviced",
        "com.apple.notificationcenterui", "com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.dock"
    ]
    private static let systemNames: Set<String> = [
        "systemsoundserverd", "systemsoundserver", "systemsoundserv", "soundserviced", "notificationcenter", "controlcenter", "systemuiserver", "dock"
    ]
    public static func isSystemSound(_ process: BudsAudioProcess) -> Bool {
        systemBundles.contains(process.bundleID?.lowercased() ?? "") || systemNames.contains(process.processName?.lowercased() ?? "")
    }
    public static func hasAppPlayback(_ processes: [BudsAudioProcess]?, output: UInt32) -> Bool {
        guard output != 0, let processes else { return false }
        return processes.contains {
            $0.runningOutput && $0.devices.contains(output) && !isSystemSound($0) &&
                ($0.bundleID?.isEmpty == false || $0.processName?.isEmpty == false)
        }
    }
}

@available(macOS 14.2, *)
public enum BudsPlaybackProcesses {
    private static func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private static func array(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [UInt32]? {
        var address = property(selector), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size <= 65536, size % 4 == 0 else { return nil }
        if size == 0 { return [] }
        var result = [UInt32](repeating: 0, count: Int(size / 4))
        let status = result.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return nil }
        return Array(result.prefix(Int(size / 4)))
    }
    private static func scalar(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = property(selector), size: UInt32 = 4, result: UInt32 = 0
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return nil }
        return result
    }
    public static func snapshot() -> [BudsAudioProcess]? {
        guard let objects = array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) else { return nil }
        return objects.map { object in
            let running = scalar(object, kAudioProcessPropertyIsRunningOutput) ?? 0
            let devices = array(object, kAudioProcessPropertyDevices) ?? []
            var address = property(kAudioProcessPropertyBundleID), size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundle: Unmanaged<CFString>?
            let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &bundle)
            var bundleID: String?
            if status == noErr, let bundle { bundleID = bundle.takeRetainedValue() as String }
            var name: String?
            if let pid = scalar(object, kAudioProcessPropertyPID) {
                var bytes = [CChar](repeating: 0, count: 4096)
                let count = bytes.withUnsafeMutableBytes { proc_pidpath(Int32(bitPattern: pid), $0.baseAddress, UInt32($0.count)) }
                if count > 0 { name = URL(fileURLWithPath: String(cString: bytes)).lastPathComponent }
                else {
                    let shortCount = bytes.withUnsafeMutableBytes { proc_name(Int32(bitPattern: pid), $0.baseAddress, UInt32($0.count)) }
                    if shortCount > 0 { name = String(cString: bytes) }
                }
            }
            return BudsAudioProcess(objectID: object, bundleID: bundleID, processName: name, runningOutput: running != 0, devices: devices)
        }
    }
}
