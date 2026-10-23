import AppKit
import CoreAudio
import Darwin

/// Core Audio emits changes; the app does not poll or record audio.
@MainActor final class BudsPlaybackObserver {
    var changed: (() -> Void)?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var output: AudioObjectID = 0
    private var started = false
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
        changed?()
    }
    func stop() {
        started = false
        for var value in listeners { AudioObjectRemovePropertyListenerBlock(value.0, &value.1, .main, value.2) }
        listeners.removeAll(); output = 0
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
