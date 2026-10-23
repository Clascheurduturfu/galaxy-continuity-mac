import Foundation
import Darwin

public struct ContinuityDevice: Identifiable, Equatable {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public var instance: String
    public var encryptedIdentity: String
    public var address: String?
}

@MainActor public final class ContinuityDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [String: NetService] = [:]
    public private(set) var devices: [ContinuityDevice] = []
    public var changed: (([ContinuityDevice]) -> Void)?
    public var failed: ((String) -> Void)?
    private var registry = NearbyPeerRegistry()
    private var bluetooth: NearbyBluetoothScanner?
    private var expiryTimer: Timer?
    private var running = false
    public private(set) var nearbyPeers: [NearbyPeer] = []
    public var nearbyChanged: (([NearbyPeer]) -> Void)?
    public var bluetoothStatus: ((String) -> Void)?
    public var profile: ContinuityProfile? {
        didSet {
            registry.resetObservations()
            registry.setPeers(profile?.peers ?? [])
            // Services may have resolved before sign-in supplied the account key.
            for service in Array(services.values) where service.hostName != nil { netServiceDidResolveAddress(service) }
            updateNearby(); startBluetooth()
        }
    }
    public override init() { super.init(); browser.delegate = self }
    public func start() {
        guard !running else { return }; running = true
        browser.searchForServices(ofType: "_mcfds._tcp.", inDomain: "local.")
        startBluetooth()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.updateNearby() } }
    }
    public func stop() {
        running = false; browser.stop(); bluetooth?.stop(); expiryTimer?.invalidate(); expiryTimer = nil
        for service in services.values { service.stop() }; services.removeAll(); devices.removeAll()
        registry.resetObservations(); changed?(devices); updateNearby()
    }
    public func setConnectedPeers(_ addresses: [String]) { registry.setConnected(addresses); updateNearby() }
    private func updateNearby() {
        registry.setNetwork(devices)
        let rows = registry.rows()
        if rows != nearbyPeers { nearbyPeers = rows; nearbyChanged?(rows) }
    }
    private func startBluetooth() {
        guard running else { bluetooth?.stop(); return }
        guard profile?.accountFingerprint?.isEmpty == false else {
            bluetooth?.stop()
            bluetoothStatus?(profile == nil ? "Sign in to identify your Samsung devices." : "Refresh the Mac connection to enable account Bluetooth discovery.")
            return
        }
        if bluetooth == nil {
            let scanner = NearbyBluetoothScanner()
            scanner.status = { [weak self] in self?.bluetoothStatus?($0) }
            scanner.observed = { [weak self] bytes in
                guard let self, let fingerprint = self.profile?.accountFingerprint else { return }
                if self.registry.observeBluetooth(bytes, fingerprint: fingerprint) { self.updateNearby() }
            }
            bluetooth = scanner
        }
        bluetooth?.start()
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let id = service.name + service.domain
        services[id] = service; service.delegate = self; service.resolve(withTimeout: 5)
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let id = service.name + service.domain
        services[id]?.stop(); services.removeValue(forKey: id); devices.removeAll { $0.id == id }; changed?(devices); updateNearby()
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) { failed?("Local-network discovery failed: \(errorDict)") }
    public func netServiceDidResolveAddress(_ sender: NetService) {
        guard running, services[sender.name + sender.domain] === sender else { return }
        guard let host = sender.hostName, sender.port > 0 else { return }
        let txt = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        let encrypted = txt["DEVICE_ID"].flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var device = ContinuityDevice(id: sender.name + sender.domain, name: "Samsung nearby device", host: host, port: sender.port, instance: sender.name, encryptedIdentity: encrypted, address: nil)
        if let profile, let nonce = Data(hex: sender.name), let cipher = Data(hex: encrypted),
           let identity = try? MCFCrypto.open(cipher, key: profile.accountKey, nonce: nonce), identity.count == 6,
           let peer = profile.peers.first(where: { (try? ContinuityProfile.addressBytes($0.address)) == identity }) {
            device.name = peer.name; device.address = peer.address
        }
        devices.removeAll { $0.id == device.id }; devices.append(device); changed?(devices); updateNearby()
    }
}

public extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0, hex.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        self.init(); var index = hex.startIndex
        while index < hex.endIndex { let end = hex.index(index, offsetBy: 2); append(UInt8(hex[index..<end], radix: 16)!); index = end }
    }
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
