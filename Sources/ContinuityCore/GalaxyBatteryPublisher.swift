import Foundation
import CryptoKit
import IOKit

/// An authenticated Galaxy's battery sample, not a Mac power supply.
public struct GalaxyBatterySample: Equatable, Sendable {
    public let address: String
    public let name: String
    public let percent: Int
    public let receivedAt: Date
    public let deviceType: String?
    public init(address: String, name: String, percent: Int, receivedAt: Date, deviceType: String? = nil) {
        self.address = address; self.name = name; self.percent = percent; self.receivedAt = receivedAt
        self.deviceType = deviceType
    }
    var usesPhoneGlyph: Bool { deviceType?.lowercased() == "phone" }
    var identifier: String? {
        guard let bytes = try? ContinuityProfile.addressBytes(address), bytes.count == 6 else { return nil }
        return "local.galaxy-continuity.battery." + SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }
    var displayName: String {
        let text = String(String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(96)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Galaxy device" : text
    }
    var details: [String: Any] {
        ["Type": "Accessory Source", "Accessory Category": usesPhoneGlyph ? "Battery Case" : "Unknown", "Accessory Identifier": identifier ?? "",
         "Name": displayName, "Transport Type": usesPhoneGlyph ? "AID" : "Bluetooth", "Power Source State": "Unknown",
         "Current Capacity": percent, "Max Capacity": 100, "Is Present": true,
         "Vendor ID": usesPhoneGlyph ? 1452 : 117, "Vendor ID Source": usesPhoneGlyph ? 2 : 1, "Product ID": usesPhoneGlyph ? 5016 : 65535]
        // Display-only compatibility hints: Apple has no generic phone glyph.
        // Its R5x battery-case representation selects iphone.smartbatterycase.gen2.
        // These fields never change Bluetooth pairing, radio transport or MCF identity.
        // Samsung does not report charging state here. Neither Is Charging nor
        // an invented AC/Battery Power state is published. This is never a UPS
        // or InternalBattery, so it cannot replace the Mac's battery.
    }
}

protocol AccessoryPowerSourceBackend: AnyObject {
    var available: Bool { get }
    func create() -> (UnsafeMutableRawPointer?, Int32)
    func update(_ handle: UnsafeMutableRawPointer, details: [String: Any]) -> Int32
    func release(_ handle: UnsafeMutableRawPointer) -> Int32
}

/// Process-owned IOKit SPI. Handles are opaque pointers, never CF objects.
final class IOKitAccessoryBackend: AccessoryPowerSourceBackend {
    private typealias Create = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
    private typealias SetDetails = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
    private typealias Release = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private let library: UnsafeMutableRawPointer?
    private let createFunction: Create?
    private let updateFunction: SetDetails?
    private let releaseFunction: Release?
    private var owned = Set<UnsafeMutableRawPointer>()
    init() {
        let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        self.library = library
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let library, let address = dlsym(library, name) else { return nil }
            return unsafeBitCast(address, to: type)
        }
        createFunction = symbol("IOPSCreatePowerSource", Create.self)
        updateFunction = symbol("IOPSSetPowerSourceDetails", SetDetails.self)
        releaseFunction = symbol("IOPSReleasePowerSource", Release.self)
    }
    var available: Bool { createFunction != nil && updateFunction != nil && releaseFunction != nil }
    func create() -> (UnsafeMutableRawPointer?, Int32) {
        guard available, let createFunction else { return (nil, Int32(kIOReturnUnsupported)) }
        var handle: UnsafeMutableRawPointer?
        let code = createFunction(&handle)
        if code == 0, let handle { owned.insert(handle) }
        return (handle, code)
    }
    func update(_ handle: UnsafeMutableRawPointer, details: [String: Any]) -> Int32 {
        guard owned.contains(handle), let updateFunction else { return Int32(kIOReturnBadArgument) }
        return updateFunction(handle, details as CFDictionary)
    }
    func release(_ handle: UnsafeMutableRawPointer) -> Int32 {
        guard owned.contains(handle), let releaseFunction else { return 0 }
        let result = releaseFunction(handle)
        if result == 0 { owned.remove(handle) }
        return result
    }
    deinit {
        for handle in owned { _ = releaseFunction?(handle) }
        if let library { dlclose(library) }
    }
}

/// Publishes only fresh, connected-device samples. One expiry task, no polling
/// loop; identical values do not rewrite powerd. All methods run on main actor.
@MainActor public final class GalaxyBatteryPublisher {
    private struct Entry { let handle: UnsafeMutableRawPointer; var sample: GalaxyBatterySample }
    private let backend: AccessoryPowerSourceBackend
    private let freshness: TimeInterval
    private let retryDelay: TimeInterval
    private let cleanupDelay: TimeInterval
    private var entries: [String: Entry] = [:]
    private var desired: [String: GalaxyBatterySample] = [:]
    private var retryAfter: [String: Date] = [:]
    private var failures: [String: Int32] = [:]
    private var retiring: [String: UnsafeMutableRawPointer] = [:]
    private var cleanupTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var expiryGeneration = UUID()
    private var publicationError: String?
    public var lastError: String? {
        if !retiring.isEmpty {
            return cleanupTask != nil ? "macOS is retrying removal of a battery entry." : "macOS could not remove a battery entry. Quit Galaxy Continuity to remove its process-owned entries."
        }
        return publicationError
    }
    public var publishedCount: Int { entries.count }
    public var available: Bool { backend.available }
    /// Request a new status only after an existing five-minute sample expires.
    public var expired: (([String]) -> Void)?
    public var changed: (() -> Void)?
    public convenience init() { self.init(backend: IOKitAccessoryBackend(), freshness: HotspotCenter.informationWindow) }
    init(backend: AccessoryPowerSourceBackend, freshness: TimeInterval, retryDelay: TimeInterval = 60, cleanupDelay: TimeInterval = 1) {
        self.backend = backend; self.freshness = freshness; self.retryDelay = max(0.01, retryDelay); self.cleanupDelay = max(0.01, cleanupDelay)
    }
    public func synchronize(_ samples: [GalaxyBatterySample], now: Date = Date()) {
        guard backend.available else { clear(); return }
        var valid: [String: GalaxyBatterySample] = [:]
        for sample in samples where (0...100).contains(sample.percent) && sample.receivedAt <= now.addingTimeInterval(5)
            && sample.receivedAt.addingTimeInterval(freshness) > now {
            guard let id = sample.identifier else { continue }
            if valid[id].map({ $0.receivedAt > sample.receivedAt }) != true { valid[id] = sample }
        }
        for id in Array(entries.keys) where valid[id] == nil { remove(id) }
        desired = valid
        retryAfter = retryAfter.filter { valid[$0.key] != nil && $0.value > now }
        failures = failures.filter { valid[$0.key] != nil && retryAfter[$0.key] != nil }
        for (id, sample) in valid {
            if var entry = entries[id] {
                if entry.sample.percent != sample.percent || entry.sample.displayName != sample.displayName || entry.sample.usesPhoneGlyph != sample.usesPhoneGlyph {
                    let result = backend.update(entry.handle, details: sample.details)
                    guard result == 0 else { failed(id, code: result, now: now); continue }
                }
                entry.sample = sample; entries[id] = entry
            } else if retryAfter[id] == nil, retiring[id] == nil {
                let (handle, result) = backend.create()
                guard result == 0, let handle else { failed(id, code: result == 0 ? -1 : result, now: now); continue }
                let code = backend.update(handle, details: sample.details)
                guard code == 0 else { retire(id, handle: handle); failed(id, code: code, now: now); continue }
                entries[id] = Entry(handle: handle, sample: sample)
            }
        }
        publicationError = failures.values.first.map { String(format: "macOS rejected a battery entry (0x%08x).", UInt32(bitPattern: $0)) }
        scheduleExpiry(now: now)
        scheduleCleanup()
        changed?()
    }
    private func failed(_ id: String, code: Int32, now: Date) {
        remove(id); retryAfter[id] = now.addingTimeInterval(retryDelay)
        failures[id] = code
    }
    private func remove(_ id: String) {
        if let entry = entries.removeValue(forKey: id) { retire(id, handle: entry.handle) }
    }
    private func retire(_ id: String, handle: UnsafeMutableRawPointer) {
        if backend.release(handle) != 0 { retiring[id] = handle }
    }
    private func scheduleCleanup() {
        guard cleanupTask == nil, !retiring.isEmpty else { return }
        cleanupTask = Task { [weak self] in
            for _ in 0..<3 {
                guard let delay = self?.cleanupDelay else { return }
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                for id in Array(self.retiring.keys) {
                    if let handle = self.retiring[id], self.backend.release(handle) == 0 { self.retiring[id] = nil }
                }
                if self.retiring.isEmpty { break }
            }
            guard let self else { return }
            self.cleanupTask = nil
            if self.retiring.isEmpty { self.synchronize(Array(self.desired.values)) }
            else { self.changed?() }
        }
    }
    private func scheduleExpiry(now: Date) {
        expiryTask?.cancel(); expiryTask = nil
        let generation = UUID(); expiryGeneration = generation
        let deadlines = desired.values.map { $0.receivedAt.addingTimeInterval(freshness) } + Array(retryAfter.values)
        guard let deadline = deadlines.min() else { return }
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0.01, deadline.timeIntervalSince(now)) * 1_000_000_000)) }
            catch { return }
            guard let self, !Task.isCancelled, self.expiryGeneration == generation else { return }
            let now = Date()
            let addresses = self.desired.values.filter { $0.receivedAt.addingTimeInterval(self.freshness) <= now }.map(\.address)
            self.synchronize(Array(self.desired.values), now: now)
            if !addresses.isEmpty { self.expired?(addresses) }
        }
    }
    public func clear() {
        expiryGeneration = UUID(); expiryTask?.cancel(); expiryTask = nil
        for id in Array(entries.keys) { remove(id) }
        desired.removeAll(); retryAfter.removeAll(); failures.removeAll(); publicationError = nil
        scheduleCleanup(); changed?()
    }
    deinit { expiryTask?.cancel(); cleanupTask?.cancel() }
}
