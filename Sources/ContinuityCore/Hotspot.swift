import Foundation
import CoreWLAN
import CoreLocation

@MainActor public final class HotspotJoiner: NSObject, @preconcurrency CLLocationManagerDelegate {
    private var location: CLLocationManager?
    private var permission: CheckedContinuation<Void, Error>?
    public var progress: ((String) -> Void)?
    public override init() { super.init() }
    public func join(_ credentials: HotspotCredentials, wasCached: Bool = false) async throws {
        try Task.checkCancellation()
        guard permission == nil else { throw ContinuityError.message("A Wi-Fi permission request is already pending.") }
        let manager = CLLocationManager(); location = manager; manager.delegate = self
        progress?("Wi-Fi location authorization state: \(manager.authorizationStatus.rawValue).")
        if manager.authorizationStatus == .notDetermined {
            try await withCheckedThrowingContinuation { continuation in
                permission = continuation; manager.requestWhenInUseAuthorization()
            }
        }
        guard manager.authorizationStatus == .authorizedAlways else {
            throw ContinuityError.message("Allow Galaxy Continuity Lab in System Settings → Privacy & Security → Location Services so macOS can find the phone's Wi-Fi network.")
        }
        guard credentials.isSuccess == true, let ssid = credentials.ssid, !ssid.isEmpty, credentials.password != nil else {
            throw ContinuityError.message("The phone did not return hotspot credentials (reason \(credentials.mhsfailed_reason ?? -1)).")
        }
        // Fast path 1: already associated to the target hotspot SSID.
        if CWWiFiClient.shared().interface()?.ssid() == ssid { return }
        // Fast path 2: try macOS's cached scan results before paying for an active full-band scan.
        if let _ = try? await Task.detached(priority: .userInitiated, operation: {
            try credentials.joinCachedOnly()
        }).value {
            return
        }
        try Task.checkCancellation()
        // When the phone just toggled its SoftAP on, give beacons a 600 ms head start
        // so the first active scan catches it instead of wasting ~4s on an empty scan.
        if !wasCached {
            progress?("Waiting briefly for the phone's hotspot radio…")
            try await Task.sleep(nanoseconds: 600_000_000)
        }
        for attempt in 0..<16 {
            try Task.checkCancellation()
            do { try await Task.detached(priority: .userInitiated) { try credentials.join() }.value; return }
            catch {
                if Task.isCancelled { throw CancellationError() }
                if attempt == 15 { throw error }
                progress?("Waiting for the phone's hotspot to become visible…")
                try await Task.sleep(nanoseconds: 450_000_000)
            }
        }
    }
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined, let pending = permission else { return }
        permission = nil
        if manager.authorizationStatus == .authorizedAlways { pending.resume() }
        else { pending.resume(throwing: ContinuityError.message("Location permission is required by macOS to discover the hotspot's Wi-Fi network.")) }
    }
}

public struct HotspotCredentials: Decodable, Sendable {
    public var messagetype: Int
    public var isSuccess: Bool?
    public var ssid: String?
    public var password: String?
    public var mhsfailed_reason: Int?
    public static func request() throws -> Data {
        // AutoHotspotMDE v0.C0104l.d(): same-account member type 1,
        // conservative 2.4/5 GHz and WPA2 capabilities.
        try JSONSerialization.data(withJSONObject: ["version": 1, "messagetype": 3, "membertype": 1, "clientsupportedhighband": 5, "clientsupportedband": 3, "wpa3personalsupport": 0, "owesupport": 0])
    }
    public static func selectBestNetwork<C: Collection>(
        _ networks: C,
        ssid: String,
        networkSSID: (C.Element) -> String?,
        rssi: (C.Element) -> Int
    ) -> C.Element? {
        networks.filter { networkSSID($0) == ssid }.max { rssi($0) < rssi($1) }
    }

    public static func selectBestNetwork(_ networks: Set<CWNetwork>, ssid: String) -> CWNetwork? {
        selectBestNetwork(networks, ssid: ssid, networkSSID: \.ssid, rssi: \.rssiValue)
    }

    public func joinCachedOnly() throws {
        guard isSuccess == true, let ssid, !ssid.isEmpty, let password else {
            throw ContinuityError.message("The phone did not return hotspot credentials (reason \(mhsfailed_reason ?? -1)).")
        }
        guard let interface = CWWiFiClient.shared().interface() else {
            throw ContinuityError.message("No Mac Wi-Fi interface is available.")
        }
        if interface.ssid() == ssid { return }
        guard let cached = interface.cachedScanResults(),
              let network = Self.selectBestNetwork(cached, ssid: ssid) else {
            throw ContinuityError.message("Hotspot not in cached scan results.")
        }
        try associateAndConfirm(interface: interface, network: network, ssid: ssid, password: password, confirmSeconds: 1.0)
    }

    public func join() throws {
        guard isSuccess == true, let ssid, !ssid.isEmpty, let password else { throw ContinuityError.message("The phone did not return hotspot credentials (reason \(mhsfailed_reason ?? -1)).") }
        guard let interface = CWWiFiClient.shared().interface() else { throw ContinuityError.message("No Mac Wi-Fi interface is available.") }
        if interface.ssid() == ssid { return }
        let networks = try interface.scanForNetworks(withSSID: Data(ssid.utf8))
        guard let network = Self.selectBestNetwork(networks, ssid: ssid) else { throw ContinuityError.message("The phone enabled its hotspot, but the Mac cannot find its Wi-Fi network. Check Wi-Fi and macOS location permission.") }
        try associateAndConfirm(interface: interface, network: network, ssid: ssid, password: password, confirmSeconds: 3.0)
    }

    private func associateAndConfirm(interface: CWInterface, network: CWNetwork, ssid: String, password: String, confirmSeconds: TimeInterval) throws {
        do {
            try interface.associate(to: network, password: password)
        } catch let associateError {
            // If macOS airportd auto-join was concurrently associating to this same
            // known hotspot SSID, associate() can fail while the link completes anyway.
            let settleDeadline = Date().addingTimeInterval(2.0)
            while interface.ssid() != ssid && Date() < settleDeadline {
                if Task.isCancelled { throw CancellationError() }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if interface.ssid() == ssid { return }
            throw associateError
        }
        let deadline = Date().addingTimeInterval(confirmSeconds)
        while interface.ssid() != ssid && Date() < deadline {
            if Task.isCancelled { throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard interface.ssid() == ssid else { throw ContinuityError.message("Wi-Fi association did not complete.") }
    }
}

/// Samsung's non-activating status reply (type 2), answered after a type-1 discovery request.
public struct HotspotInformation: Decodable, Sendable {
    public let messagetype: Int
    public let batteryLevel: Int?
    public let internet_availablity: Bool?
    public let backhaulnetworktype: Int?
    public var batteryPercent: Int? { batteryLevel.flatMap { (0...100).contains($0) ? $0 : nil } }
    public static func request() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 1, "messagetype": 1, "membertype": 1])
    }
}

/// Cache for Auto Hotspot answers, keyed by Bluetooth address. Queries are
/// on demand only (button click, Wi-Fi-menu open, Wi-Fi-menu click); a cached
/// answer is reused for `freshWindow` seconds, and everything is dropped on
/// wake, disconnect or any explicit invalidation — after that the phone is
/// re-asked over the existing session.
@MainActor public final class HotspotCenter {
    /// Inside the 15–30 s window the user asked for.
    public static let freshWindow: TimeInterval = 20
    private var cache: [String: (credentials: HotspotCredentials, at: Date)] = [:]
    private var information: [String: (HotspotInformation, Date)] = [:]
    private var knownSSIDs: [String: String] = [:]
    public func lastSSID(address: String) -> String? { knownSSIDs[address] }
    public static let informationWindow: TimeInterval = 300
    public init() {}
    public func information(address: String) -> HotspotInformation? {
        informationSnapshot(address: address)?.value
    }
    public func informationSnapshot(address: String) -> (value: HotspotInformation, receivedAt: Date)? {
        guard let value = information[address] else { return nil }
        let age = Date().timeIntervalSince(value.1)
        guard age >= 0, age < Self.informationWindow else { return nil }
        return (value.0, value.1)
    }
    public func storeInformation(address: String, value: HotspotInformation) { information[address] = (value, Date()) }
    /// A still-fresh answer for the device, or nil when it must be re-requested.
    public func cached(address: String) -> HotspotCredentials? {
        guard let entry = cache[address], Date().timeIntervalSince(entry.at) <= Self.freshWindow else { return nil }
        return entry.credentials
    }
    public func store(address: String, credentials: HotspotCredentials) {
        cache[address] = (credentials, Date())
        if credentials.isSuccess == true, let ssid = credentials.ssid, !ssid.isEmpty { knownSSIDs[address] = ssid }
    }
    public func invalidate(address: String? = nil) {
        if let address { cache[address] = nil; information[address] = nil; knownSSIDs[address] = nil } else { cache.removeAll(); information.removeAll(); knownSSIDs.removeAll() }
    }
}

/// Remembers which nearby devices answered the hotspot request with a
/// failure, so they are excluded from new requests and hidden from the
/// Wi-Fi menu entry instead of being asked again on every interaction.
@MainActor public final class HotspotCapabilityMemory {
    /// How long a "no hotspot" verdict is trusted before it can be re-checked.
    public static let trustWindow: TimeInterval = 120
    private let defaults: UserDefaults
    private let key = "hotspot.unavailableDevices"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func table() -> [String: Double] {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return value
    }
    private func store(_ table: [String: Double]) {
        guard let data = try? JSONEncoder().encode(table.filter { Date().timeIntervalSince1970 - abs($0.value) < Self.trustWindow }) else { return }
        defaults.set(data, forKey: key)
    }
    /// True while a recorded failure is still trusted.
    public func unavailable(_ address: String) -> Bool {
        guard let at = table()[address] else { return false }
        return Date().timeIntervalSince1970 - abs(at) < Self.trustWindow
    }
    public func markUnavailable(_ address: String, reason: Int?) {
        var value = table(); value[address] = Date().timeIntervalSince1970; store(value)
    }
    /// A successful answer (or a retry by the user) clears the verdict.
    public func markAvailable(_ address: String) {
        var value = table(); value[address] = nil; store(value)
    }
}
