import Foundation
import CoreBluetooth
import CryptoKit

public enum MCFAdvertisement {
    /// Account obfuscation from Galaxy Connect 4.6. This only identifies a candidate;
    /// the GCM account handshake and registered-device check authenticate the peer.
    public static func cocPSM(manufacturer: Data, fingerprint: Data, targetAddress: String? = nil, now: Date = Date()) -> UInt16? {
        guard let context = context(manufacturer: manufacturer, fingerprint: fingerprint, targetAddress: targetAddress, now: now) else { return nil }
        let raw = Array(context), start = Int(raw[14]), length = Int(raw[15])
        var cursor = start
        while cursor < start + length {
            let count = Int(raw[cursor] >> 4), type = raw[cursor] & 15; cursor += 1
            if type == 1, count >= 5 {
                let psm = UInt16(raw[cursor]) << 8 | UInt16(raw[cursor + 1])
                return psm == 0 ? nil : psm
            }
            cursor += count
        }
        return nil
    }
    public static func context(manufacturer: Data, fingerprint: Data, targetAddress: String? = nil, now: Date = Date()) -> Data? {
        var raw = Array(manufacturer.dropFirst(2))
        guard manufacturer.prefix(2) == Data([0x75, 0]), raw.count >= 16, raw[0] == 2, raw[1] == 24, raw[13] & 15 == 1 else { return nil }
        let table = Array(SHA256.hash(data: fingerprint)), rotation = Int(now.timeIntervalSince1970 * 1000) / 43_200_000
        let checks = [rotation, rotation - 1].map { r in (0..<10).reduce(UInt8(0)) { $0 ^ table[(($1 - r) % 32 + 32) % 32] } }
        guard checks.contains(raw[2]) else { return nil }
        let start = Int(raw[14]), length = Int(raw[15])
        guard start >= 16, start <= raw.count, length <= raw.count - start else { return nil }
        let seed = Int(raw[5..<13].reduce(UInt8(0), ^)) % table.count
        for i in start..<raw.count { raw[i] ^= table[(seed + i) % table.count] }
        var cursor = start
        var hint = Data()
        while cursor < start + length {
            let count = Int(raw[cursor] >> 4), type = raw[cursor] & 15; cursor += 1
            guard count <= start + length - cursor else { return nil }
            if type == 4, count == 3 || count == 4 { hint = Data(raw[(cursor + 1)..<(cursor + count)]) }
            cursor += count
        }
        if let targetAddress {
            guard let address = try? ContinuityProfile.addressBytes(targetAddress), !hint.isEmpty,
                  hint == Data(address.dropFirst(3).prefix(hint.count)) else { return nil }
        }
        return Data(raw)
    }
}

/// Direct BLE credit-based L2CAP connection. All callbacks and callers use the
/// main run loop. There is no Windows or ADB relay in this transport.
@MainActor public final class BLEMCFTransport: NSObject, MCFConnection, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate, @preconcurrency StreamDelegate {
    private var manager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var channel: CBL2CAPChannel?
    private let fingerprint: Data
    private let targetAddress: String?
    private var psm: UInt16 = 0
    private var connecting: CheckedContinuation<Void, Error>?
    private var receiving: CheckedContinuation<MCFPacket, Error>?
    private var sending: CheckedContinuation<Void, Error>?
    private var pendingWrites: [(Data, CheckedContinuation<Void, Error>)] = []
    private var closed = false
    private var incoming = Data(), outgoing = Data()
    public var status: ((String) -> Void)?
    public var contextChanged: ((Data) -> Void)?
    public private(set) var lastContext: Data?
    public init(profile: ContinuityProfile) throws {
        guard let fp = profile.accountFingerprint, !fp.isEmpty else { throw ContinuityError.message("This profile lacks the account discovery fingerprint. Export a fresh connection.") }
        fingerprint = fp; targetAddress = profile.preferredPeerAddress; super.init()
    }
    public func connect() async throws {
        try await withCheckedThrowingContinuation { continuation in
            status?("Starting Bluetooth manager (main thread: \(Thread.isMainThread))…")
            connecting = continuation; manager = CBCentralManager(delegate: self, queue: .main)
        }
    }
    public func cancel() { finish(ContinuityError.message("Bluetooth connection closed or timed out.")) }
    private func finish(_ error: Error) {
        guard !closed else { return }; closed = true
        if manager?.state == .poweredOn { manager?.stopScan() }
        channel?.inputStream.close(); channel?.outputStream.close()
        channel?.inputStream.remove(from: .main, forMode: .common); channel?.outputStream.remove(from: .main, forMode: .common)
        if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
        let c = connecting; connecting = nil; c?.resume(throwing: error)
        let r = receiving; receiving = nil; r?.resume(throwing: error)
        let s = sending; sending = nil; s?.resume(throwing: error)
        let pending = pendingWrites; pendingWrites.removeAll(); for (_, c) in pending { c.resume(throwing: error) }
        channel = nil
    }
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !closed else { return }
        status?("Bluetooth state \(central.state.rawValue), permission \(CBManager.authorization.rawValue).")
        if central.state == .poweredOn { status?("Scanning Samsung account advertisements…"); central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]) }
        else if central.state != .unknown && central.state != .resetting { finish(ContinuityError.message("Bluetooth unavailable (state \(central.state.rawValue), permission \(CBManager.authorization.rawValue)).")) }
    }
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !closed, let bytes = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        if let active = self.peripheral {
            // A Samsung device can advertise through another BLE advertising
            // identity while its CoC remains open. The account fingerprint and
            // selected registered-device hint identify these context updates.
            if active.identifier == peripheral.identifier || targetAddress != nil,
               let context = MCFAdvertisement.context(manufacturer: bytes, fingerprint: fingerprint, targetAddress: targetAddress) {
                lastContext = context; contextChanged?(context)
            }
            return
        }
        guard let psm = MCFAdvertisement.cocPSM(manufacturer: bytes, fingerprint: fingerprint, targetAddress: targetAddress) else { return }
        lastContext = MCFAdvertisement.context(manufacturer: bytes, fingerprint: fingerprint, targetAddress: targetAddress)
        self.peripheral = peripheral; self.psm = psm; peripheral.delegate = self
        status?("Samsung account candidate found; connecting to BLE CoC PSM \(psm)…"); central.connect(peripheral)
    }
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { status?("BLE connected; opening the continuity channel…"); peripheral.openL2CAPChannel(psm) }
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { finish(error ?? ContinuityError.message("BLE connection failed.")) }
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { finish(error ?? ContinuityError.message("The Samsung device disconnected.")) }
    public func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel, error == nil else { finish(error ?? ContinuityError.message("The Samsung BLE CoC channel did not open.")); return }
        self.channel = channel
        for stream in [channel.inputStream as Stream, channel.outputStream as Stream] { stream.delegate = self; stream.schedule(in: .main, forMode: .common); stream.open() }
        status?("BLE CoC open; authenticating the Samsung account…")
        let c = connecting; connecting = nil; c?.resume()
    }
    public func send(_ packet: MCFPacket) async throws {
        guard channel != nil, !closed else { throw ContinuityError.message("BLE output unavailable.") }
        try await withCheckedThrowingContinuation { continuation in
            pendingWrites.append((packet.framed, continuation)); startNextWrite()
        }
    }
    private func startNextWrite() {
        guard sending == nil, !pendingWrites.isEmpty else { return }
        let next = pendingWrites.removeFirst(); outgoing = next.0; sending = next.1; writeAvailable()
    }
    private func writeAvailable() {
        guard let stream = channel?.outputStream else { return }
        while !outgoing.isEmpty && stream.hasSpaceAvailable {
            let n = outgoing.withUnsafeBytes { stream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: outgoing.count) }
            if n < 0 { finish(stream.streamError ?? ContinuityError.message("BLE write failed.")); return }
            if n == 0 { return }; outgoing = Data(outgoing.dropFirst(n))
        }
        if outgoing.isEmpty { let s = sending; sending = nil; s?.resume(); startNextWrite() }
    }
    public func receive() async throws -> MCFPacket {
        guard channel != nil, receiving == nil else { throw ContinuityError.message("BLE input unavailable or busy.") }
        return try await withCheckedThrowingContinuation { continuation in receiving = continuation; deliverPacket() }
    }
    private func deliverPacket() {
        guard receiving != nil else { return }
        do {
            var cursor = 0
            guard let length = try? ProtoWire.readVarint(incoming, cursor: &cursor) else {
                if incoming.count >= 10 { throw ContinuityError.message("Invalid BLE frame prefix.") }; return
            }
            guard length <= ProtoWire.maximumFrame else { throw ContinuityError.message("BLE frame is too large.") }
            guard incoming.count >= cursor + Int(length) else { return }
            let body = Data(incoming.dropFirst(cursor).prefix(Int(length))); incoming = Data(incoming.dropFirst(cursor + Int(length)))
            let packet = try MCFPacket(data: body); let r = receiving; receiving = nil; r?.resume(returning: packet)
        } catch { finish(error) }
    }
    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        if eventCode.contains(.errorOccurred) || eventCode.contains(.endEncountered) { finish(aStream.streamError ?? ContinuityError.message("BLE stream ended.")); return }
        if eventCode.contains(.hasSpaceAvailable) { writeAvailable() }
        if eventCode.contains(.hasBytesAvailable), let stream = aStream as? InputStream {
            var bytes = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&bytes, maxLength: bytes.count)
                if n < 0 { finish(stream.streamError ?? ContinuityError.message("BLE read failed.")); return }
                if n == 0 { break }; incoming.append(contentsOf: bytes.prefix(n))
                if incoming.count > ProtoWire.maximumFrame + 65546 { finish(ContinuityError.message("BLE receive buffer exceeded its limit.")); return }
            }
            deliverPacket()
        }
    }
}
