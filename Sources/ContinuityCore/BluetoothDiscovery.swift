import Foundation
import CoreBluetooth

/// Bounded diagnostics. No nearby advertisement payload or Bluetooth address is logged.
public final class BluetoothDiscovery: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    public static let hotspotService = CBUUID(string: "7c7bcc5e-27a2-11e9-ab14-d663bd873d93")
    private var manager: CBCentralManager!
    private var seen = Set<UUID>()
    public private(set) var samsungCount = 0
    public private(set) var hotspotPeers: [CBPeripheral] = []
    public private(set) var samsungFrames: [[String: String]] = []
    public var status: ((String) -> Void)?
    public var found: ((CBPeripheral) -> Void)?
    public override init() { super.init(); manager = CBCentralManager(delegate: self, queue: .main) }
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        status?("Bluetooth state: \(central.state.rawValue); authorization: \(CBManager.authorization.rawValue)")
        if central.state == .poweredOn { central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]) }
    }
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard seen.insert(peripheral.identifier).inserted else { return }
        if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, data.count >= 2,
           data[data.startIndex] == 0x75, data[data.startIndex + 1] == 0 {
            samsungCount += 1
            if samsungFrames.count < 128 { samsungFrames.append(["identifier": peripheral.identifier.uuidString, "manufacturer": data.base64EncodedString(), "connectable": String(describing: advertisementData[CBAdvertisementDataIsConnectable] ?? false)]) }
        }
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []) + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        if services.contains(Self.hotspotService) { hotspotPeers.append(peripheral); found?(peripheral) }
    }
    public var nearbyCount: Int { seen.count }
    public func stop() { manager.stopScan() }
}
