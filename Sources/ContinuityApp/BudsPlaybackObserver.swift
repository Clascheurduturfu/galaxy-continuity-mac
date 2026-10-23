import AppKit
import CoreAudio
import Darwin
import ContinuityCore

/// Core Audio emits changes; the app does not poll or record audio.
@MainActor final class BudsPlaybackObserver {
    var changed: (() -> Void)?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var output: AudioObjectID = 0
    private var started = false
    private var processIDs = Set<AudioObjectID>()
    private var processListListening = false
    private var sources: [BudsAudioProcess]?
    var trackProcesses = false { didSet { if oldValue != trackProcesses && started { refresh() } } }
    var appPlaybackActive: Bool { BudsPlaybackPolicy.hasAppPlayback(sources, output: output) }
    static var processFilteringAvailable: Bool { if #available(macOS 14.2, *) { return true }; return false }
    private func remove(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        for index in listeners.indices.reversed() where listeners[index].0 == object && listeners[index].1.mSelector == selector {
            var value = listeners.remove(at: index)
            AudioObjectRemovePropertyListenerBlock(value.0, &value.1, .main, value.2)
        }
    }
    private func add(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr { listeners.append((object, address, block)) }
    }
    func start() {
        guard !started else { refresh(); return }; started = true
        add(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        add(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        refresh()
    }
    private func refresh() {
        guard started else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device: AudioObjectID = 0, size = UInt32(MemoryLayout<AudioObjectID>.size)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != output {
            if let index = listeners.firstIndex(where: { $0.0 == output }) {
                var old = listeners.remove(at: index)
                AudioObjectRemovePropertyListenerBlock(old.0, &old.1, .main, old.2)
            }
            output = device
            if device != 0 { add(device, kAudioDevicePropertyDeviceIsRunningSomewhere) }
        }
        if #available(macOS 14.2, *) {
            let system = AudioObjectID(kAudioObjectSystemObject)
            if trackProcesses {
                if !processListListening { add(system, kAudioHardwarePropertyProcessObjectList); processListListening = true }
                sources = BudsPlaybackProcesses.snapshot()
                let current = Set(sources?.map(\.objectID) ?? [])
                for id in processIDs.subtracting(current) {
                    remove(id, kAudioProcessPropertyIsRunningOutput); remove(id, kAudioProcessPropertyDevices)
                }
                for id in current.subtracting(processIDs) {
                    add(id, kAudioProcessPropertyIsRunningOutput); add(id, kAudioProcessPropertyDevices)
                }
                processIDs = current
            } else {
                remove(system, kAudioHardwarePropertyProcessObjectList); processListListening = false
                for id in processIDs { remove(id, kAudioProcessPropertyIsRunningOutput); remove(id, kAudioProcessPropertyDevices) }
                processIDs.removeAll(); sources = nil
            }
        }
        changed?()
    }
    func stop() {
        started = false
        for var value in listeners { AudioObjectRemovePropertyListenerBlock(value.0, &value.1, .main, value.2) }
        listeners.removeAll(); output = 0; processIDs.removeAll(); sources = nil; processListListening = false
    }
}

/// Sends an explicit PAUSE, never play/pause toggle (which could start an idle player).
/// MediaRemote is private and may reject commands on future macOS versions.
@MainActor enum MacMediaPause {
    static func request() -> Bool {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY) else { return false }
        defer { dlclose(handle) }
        typealias Command = @convention(c) (UInt32, CFDictionary?) -> Bool
        guard let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else { return false }
        return unsafeBitCast(symbol, to: Command.self)(1, nil)
    }
}
