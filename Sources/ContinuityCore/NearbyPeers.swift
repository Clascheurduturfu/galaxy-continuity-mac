import Foundation
import CoreBluetooth

/// Account membership, radio observations and authenticated connections are separate facts.
public struct NearbyPeer: Identifiable, Equatable {
    public let id: String
    public let address: String
    public let name: String
    public let deviceType: String?
    public let bluetoothNearby: Bool
    public let bluetoothConnectable: Bool
    public let network: ContinuityDevice?
    public let connected: Bool
    public var nearby: Bool { connected || bluetoothNearby || network != nil }
    public var summary: String {
        if connected { return "Connected" }
        if bluetoothNearby && network != nil { return "Nearby over Bluetooth and local network" }
        if bluetoothNearby { return "Nearby over Bluetooth · account handshake required" }
        if network != nil { return "Found on the local network · account handshake required" }
        return "Samsung account device · not detected nearby"
    }
    public var symbol: String {
        switch deviceType?.lowercased() {
        case "pc", "computer": return "laptopcomputer"
        case "tablet", "tab": return "ipad"
        default: return "iphone"
        }
    }
}

/// Pure state reducer, also used by offline discovery tests. Radio hints identify
/// candidates only; the normal account handshake still authenticates connections.
public struct NearbyPeerRegistry {
    public static let bluetoothLifetime: TimeInterval = 40
    private var peers: [ContinuityProfile.Peer] = []
    private var bluetooth: [String: (Date, Date?)] = [:]
    private var network: [String: ContinuityDevice] = [:]
    private var connected = Set<String>()
    public init() {}
    private static func key(_ address: String) -> String {
        address.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased()
    }
    public mutating func setPeers(_ peers: [ContinuityProfile.Peer]) {
        var seen = Set<String>()
        self.peers = peers.filter { seen.insert(Self.key($0.address)).inserted }
        let allowed = Set(peers.map { Self.key($0.address) })
        bluetooth = bluetooth.filter { allowed.contains($0.key) }
        network = network.filter { allowed.contains($0.key) }
        connected.formIntersection(allowed)
    }
    public mutating func resetObservations() { bluetooth.removeAll(); network.removeAll(); connected.removeAll() }
    public mutating func setConnected(_ addresses: [String]) { connected = Set(addresses.map(Self.key)) }
    public mutating func setNetwork(_ devices: [ContinuityDevice]) {
        network.removeAll()
        for device in devices {
            guard let address = device.address, device.port > 0, device.port <= 65535, !device.host.isEmpty else { continue }
            network[Self.key(address)] = device
        }
    }
    @discardableResult public mutating func observeBluetooth(_ manufacturer: Data, fingerprint: Data, now: Date = Date()) -> Bool {
        // A short address hint can collide. Do not assign an ambiguous packet to
        // either account peer, or treat a general Samsung packet as our device.
        guard let context = MCFAdvertisement.context(manufacturer: manufacturer, fingerprint: fingerprint, now: now) else { return false }
        let candidates = peers.filter { MCFAdvertisement.matchesAddress(context: context, address: $0.address) }
        guard candidates.count == 1, let peer = candidates.first else { return false }
        let connectable = MCFAdvertisement.cocPSM(manufacturer: manufacturer, fingerprint: fingerprint, targetAddress: peer.address, now: now) != nil
        let key = Self.key(peer.address)
        bluetooth[key] = (now, connectable ? now : bluetooth[key]?.1)
        return true
    }
    public func rows(now: Date = Date()) -> [NearbyPeer] {
        var seen = Set<String>()
        return peers.compactMap { peer -> NearbyPeer? in
            let key = Self.key(peer.address)
            guard seen.insert(key).inserted else { return nil }
            let observation = bluetooth[key]
            let fresh = observation.map { now.timeIntervalSince($0.0) >= 0 && now.timeIntervalSince($0.0) <= Self.bluetoothLifetime } ?? false
            return NearbyPeer(id: key, address: peer.address, name: peer.name, deviceType: peer.deviceType,
                              bluetoothNearby: fresh, bluetoothConnectable: fresh && observation?.1.map { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) <= Self.bluetoothLifetime } == true,
                              network: network[key], connected: connected.contains(key))
        }.sorted {
            if $0.connected != $1.connected { return $0.connected }
            if $0.nearby != $1.nearby { return $0.nearby }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// Observes every account candidate without connecting, pairing, or stopping when
/// the first phone is found. Advertisement payloads stay in memory and are not logged.
@MainActor final class NearbyBluetoothScanner: NSObject, @preconcurrency CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private var running = false
    var observed: ((Data) -> Void)?
    var status: ((String) -> Void)?
    func start() {
        running = true
        if manager == nil { manager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false]) }
        else if manager?.state == .poweredOn { scan() }
    }
    func stop() { running = false; manager?.stopScan() }
    private func scan() {
        guard running else { return }
        status?("Looking for Samsung devices over Bluetooth and the local network.")
        manager?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard running else { return }
        switch central.state {
        case .poweredOn: scan()
        case .poweredOff: status?("Bluetooth is off. Account devices and local-network discovery remain available.")
        case .unauthorized: status?("Allow Bluetooth for Galaxy Continuity Lab in System Settings to detect nearby devices.")
        case .unsupported: status?("Bluetooth discovery is unavailable on this Mac.")
        default: status?("Waiting for Bluetooth…")
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard running, let bytes = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        observed?(bytes)
    }
}

/// Home prioritizes a phone without re-routing independent clipboard/feature sessions.
public enum GalaxyPeerPreference {
    public static func home(peers: [ContinuityProfile.Peer], connected: [String], nearby: [String], selected: String) -> ContinuityProfile.Peer? {
        func key(_ s: String) -> String { s.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased() }
        let live = Set(connected.map(key)), seen = Set(nearby.map(key))
        let phones = peers.filter { $0.deviceType?.lowercased() == "phone" }
        return phones.first { live.contains(key($0.address)) }
            ?? phones.first { seen.contains(key($0.address)) }
            ?? phones.first { key($0.address) == key(selected) }
            ?? phones.first
            ?? peers.first { key($0.address) == key(selected) }
            ?? peers.first
    }
}
