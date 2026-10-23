import Foundation
@preconcurrency import IOBluetooth

public struct PairedBuds: Identifiable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = Self.canonicalID(id)
        self.name = name
    }
    public static func canonicalID(_ value: String) -> String {
        let hex = value.filter { $0.isHexDigit }.uppercased()
        guard hex.count == 12 else { return value.uppercased() }
        return stride(from: 0, to: 12, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[start..<hex.index(start, offsetBy: 2)])
        }.joined(separator: "-")
    }
    public static func unique(_ values: [PairedBuds]) -> [PairedBuds] {
        var seen = Set<String>()
        return values.filter { seen.insert(canonicalID($0.id)).inserted }
    }
}

/// A paired headset's serial control channel. Closing it leaves Bluetooth audio alone.
@MainActor public final class BudsConnection: NSObject, @preconcurrency IOBluetoothRFCOMMChannelDelegate {
    private static let services = ["F8620674-A1ED-41AB-A8B9-DE9AD655729D", "00001101-0000-1000-8000-00805F9B34FD", "00001101-0000-1000-8000-00805F9B34FB"]
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var querying: CheckedContinuation<Void, Error>?
    private var opening: CheckedContinuation<Void, Error>?
    private var deadline: Task<Void, Never>?
    private var decoder = BudsPacketDecoder()
    public var status: ((String) -> Void)?
    public var received: ((BudsPacket) -> Void)?
    public var diagnostic: ((String) -> Void)?
    public var closed: (() -> Void)?
    public private(set) var connected = false

    private static func uuid(_ string: String) -> IOBluetoothSDPUUID? {
        guard var value = UUID(uuidString: string)?.uuid else { return nil }
        return withUnsafePointer(to: &value) { IOBluetoothSDPUUID(bytes: $0, length: 16) }
    }
    public static func pairedDevices() -> [PairedBuds] {
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return PairedBuds.unique(devices.compactMap { device in
            guard let address = device.addressString, let name = device.name else { return nil }
            let samsungService = services.prefix(2).contains { text in
                guard let uuid = uuid(text) else { return false }
                return device.getServiceRecord(for: uuid) != nil
            }
            guard name.localizedCaseInsensitiveContains("buds") || samsungService else { return nil }
            return PairedBuds(id: address, name: name)
        }).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public static func disconnectPairedDevice(address: String) throws {
        guard let selected = IOBluetoothDevice(addressString: address), selected.isPaired() else {
            throw ContinuityError.message("Choose paired Buds first.")
        }
        let result = selected.closeConnection()
        guard result == kIOReturnSuccess else { throw ContinuityError.message(String(format: "Disconnecting Buds failed (0x%08x).", result)) }
    }
    public func connect(address: String) async throws {
        guard !connected, querying == nil, opening == nil else { throw ContinuityError.message("A Buds connection is already active.") }
        guard let selected = IOBluetoothDevice(addressString: address), selected.isPaired() else {
            throw ContinuityError.message("Pair the Galaxy Buds with this Mac in Bluetooth settings first.")
        }
        device = selected
        diagnostic?("Paired device connected: \(selected.isConnected()); cached services: \(selected.services?.count ?? 0).")
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
            self?.fail(ContinuityError.message("The Buds connection timed out. Keep them nearby and try again."))
        }
        defer { deadline?.cancel(); deadline = nil }
        if controlChannel(selected) == nil {
            status?("Discovering the paired Buds control service…")
            try await withCheckedThrowingContinuation { continuation in
                querying = continuation
                let result = selected.performSDPQuery(self, uuids: Self.services.compactMap(Self.uuid))
                diagnostic?(String(format: "Service discovery started (0x%08x).", result))
                if result != kIOReturnSuccess { fail(ioError("Buds service discovery", result)) }
            }
        }
        guard let number = controlChannel(selected) else { throw ContinuityError.message("The paired device does not expose a supported Galaxy Buds serial service.") }
        status?("Opening the Buds control channel…")
        try await withCheckedThrowingContinuation { continuation in
            opening = continuation
            var newChannel: IOBluetoothRFCOMMChannel?
            let result = selected.openRFCOMMChannelAsync(&newChannel, withChannelID: number, delegate: self)
            channel = newChannel
            if result != kIOReturnSuccess { fail(ioError("Opening Buds control", result)) }
        }
        try send(.features)
        try send(.computerInfo)
        diagnostic?("Host manufacturer: Apple; product unspecified.")
        try send(.mdeVersion(3))
        status?("Buds control connected. Choose Take audio to request a switch.")
    }
    @objc public func sdpQueryComplete(_ queried: IOBluetoothDevice!, status result: IOReturn) {
        diagnostic?(String(format: "Service discovery callback (0x%08x).", result))
        guard queried == device, let pending = querying else { return }
        querying = nil
        if result == kIOReturnSuccess { pending.resume() }
        else { pending.resume(throwing: ioError("Buds service discovery", result)) }
    }
    private func controlChannel(_ device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        for uuid in Self.services.compactMap(Self.uuid) {
            var channel: BluetoothRFCOMMChannelID = 0
            if let record = device.getServiceRecord(for: uuid), record.getRFCOMMChannelID(&channel) == kIOReturnSuccess, channel != 0 { return channel }
        }
        return nil
    }
    public func rfcommChannelOpenComplete(_ opened: IOBluetoothRFCOMMChannel!, status result: IOReturn) {
        guard let pending = opening else { if result == kIOReturnSuccess { _ = opened?.close() }; return }
        opening = nil
        guard result == kIOReturnSuccess, let opened else { pending.resume(throwing: ioError("Opening Buds control", result)); return }
        channel = opened; connected = true; pending.resume()
    }
    public func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length count: Int) {
        guard connected, channel == self.channel, let pointer, count > 0, count <= 65_536 else { return }
        for packet in decoder.append(Data(bytes: pointer, count: count)) { received?(packet) }
    }
    public func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        guard channel == self.channel else { return }
        fail(ContinuityError.message("The Buds control channel closed."))
    }
    public func send(_ packet: BudsPacket) throws {
        guard connected, let channel else { throw ContinuityError.message("Connect the Buds control channel first.") }
        var bytes = try packet.encoded()
        let result = bytes.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: UInt16($0.count)) }
        guard result == kIOReturnSuccess else { throw ioError("Writing Buds control", result) }
    }
    public func takeAudio() throws { try send(.takeAudio) }
    public func disconnect() { fail(ContinuityError.message("Buds control disconnected.")) }
    private func ioError(_ action: String, _ result: IOReturn) -> Error {
        ContinuityError.message(action + String(format: " failed (0x%08x).", result))
    }
    private func fail(_ error: Error) {
        deadline?.cancel(); deadline = nil
        let q = querying; querying = nil; q?.resume(throwing: error)
        let o = opening; opening = nil; o?.resume(throwing: error)
        let wasConnected = connected; connected = false
        if let channel { _ = channel.setDelegate(nil); _ = channel.close() }
        channel = nil; device = nil; decoder = BudsPacketDecoder()
        if wasConnected { status?(error.localizedDescription); closed?() }
    }
}
