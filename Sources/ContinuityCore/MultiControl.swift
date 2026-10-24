import Foundation

public enum MultiControlWire {
    public static func deviceID(address: String) -> String {
        let hash = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf16.reduce(Int32(0)) { ($0 &* 31) &+ Int32($1) }
        return String(hash)
    }
    public static func message(_ name: String, parameters: [String: Any], from: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["MSG": name, "PARAM": parameters, "FROM": from]) + Data([10])
    }
    public static func key(scanCode: UInt16, down: Bool) -> Data { Data([75, down ? 0 : 1, UInt8(scanCode >> 8), UInt8(scanCode & 255)]) }
    public static func click(button: UInt8, down: Bool) -> Data { Data([67, down ? 0 : 1, button]) }
    public static func motion(x: Int, y: Int, wheel: Bool = false, elapsed: UInt8 = 0) -> Data {
        let a = UInt16(bitPattern: Int16(clamping: x)), b = UInt16(bitPattern: Int16(clamping: y))
        return Data([wheel ? 87 : 77, UInt8(a >> 8), UInt8(a & 255), UInt8(b >> 8), UInt8(b & 255), elapsed])
    }
    /// Ordinary movement packets: a total equal to the reserved (-100,-100)
    /// marker is split in two so the phone never mistakes it for a focus
    /// release. The first carries `elapsed`, the second 0.
    public static func pointerPackets(x: Int, y: Int, elapsed: UInt8 = 0) -> [Data] {
        PointerVector.safeParts(x: x, y: y).enumerated().map { motion(x: $1.x, y: $1.y, elapsed: $0 == 0 ? elapsed : 0) }
    }
    /// The Book's explicit "focus returned to the PC" vector; clears the phone's pending mouse queue.
    public static var focusReleaseMarker: Data { motion(x: PointerVector.reserved.x, y: PointerVector.reserved.y) }
}

/// Direct input path for the capture worker: keys, clicks, wheels and
/// TCP-fallback movements go straight onto the feature channel with no actor
/// hop, mirroring the Book's hook-thread sends. Tracks held keys and buttons
/// so a control hand-back can always release them.
public final class ReliableInputSender: @unchecked Sendable {
    private let lock = NSLock()
    private var pressedKeys: Set<UInt16> = []
    private var pressedButtons: Set<UInt8> = []
    private let send: (Data) throws -> Void
    private let gate: AtomicFlag
    /// Called on the capture worker when the channel rejects input; the engine ends control.
    public var onUnavailable: ((String) -> Void)?
    public init(gate: AtomicFlag, send: @escaping (Data) throws -> Void) { self.gate = gate; self.send = send }
    public var isControlling: Bool { gate.value }
    /// Sends one input; returns the reliable queue depth (always 0 now that
    /// sends are synchronous), matching the `PointerOutput` contract.
    public func send(_ input: PhoneInput) -> Int {
        guard gate.value else { return 0 }
        do {
            switch input {
            case let .key(code, down):
                try send(MultiControlWire.key(scanCode: code, down: down))
                lock.lock(); if down { pressedKeys.insert(code) } else { pressedKeys.remove(code) }; lock.unlock()
            case let .click(button, down):
                try send(MultiControlWire.click(button: button, down: down))
                lock.lock(); if down { pressedButtons.insert(button) } else { pressedButtons.remove(button) }; lock.unlock()
            case let .move(x, y, elapsed):
                for packet in MultiControlWire.pointerPackets(x: x, y: y, elapsed: elapsed) { try send(packet) }
            case let .wheel(x, y):
                try send(MultiControlWire.motion(x: x, y: y, wheel: true, elapsed: 0))
            }
        } catch { onUnavailable?(error.localizedDescription) }
        return 0
    }
    /// Releases anything still held when control ends; bypasses the gate by design.
    public func releaseHeld() {
        lock.lock(); let keys = pressedKeys; let buttons = pressedButtons; pressedKeys = []; pressedButtons = []; lock.unlock()
        for key in keys { try? send(MultiControlWire.key(scanCode: key, down: false)) }
        for button in buttons { try? send(MultiControlWire.click(button: button, down: false)) }
    }
}

@MainActor public final class MultiControl {
    private let session = FeatureSession(appID: 1)
    private var ownID = ""
    private var phoneID = ""
    private var jsonBuffer = Data()
    private var phoneSize = (1080, 2400)
    private var phoneDisplay: [String: Any] = [:]
    private var placement = DevicePlacement()
    private var hostSize = (1440, 900)
    private var lastLayoutSignature = ""
    private var sequence = 0
    private var ownInformation: [String: Any]?
    private var informationResends = 0
    private var focusRegains = 0
    private var pressedKeys: Set<UInt16> = []
    private var pressedButtons: Set<UInt8> = []
    public private(set) var connected = false
    public private(set) var controlling = false { didSet { controlGate.value = controlling } }
    /// Thread-safe mirror of `controlling` for the pointer worker.
    public let controlGate = AtomicFlag()
    private let options = PointerOptions.load()
    public var status: ((String) -> Void)?
    public var changed: (() -> Void)?
    public var released: (() -> Void)?
    public var focusReturned: (() -> Void)?
    public init() {
        session.status = { [weak self] in self?.status?($0) }
        session.received = { [weak self] data in
            Task { @MainActor in
                do { try await self?.handle(data) }
                catch { self?.status?(error.localizedDescription); await self?.release() }
            }
        }
    }
    public func connect(profile: ContinuityProfile, width: Int, height: Int, host: String? = nil, port: UInt16? = nil, sharing command: ClipboardSession? = nil) async throws {
        await disconnect(); ownID = MultiControlWire.deviceID(address: profile.localBluetoothAddress); phoneID = ""; jsonBuffer = Data(); hostSize = (width, height); lastLayoutSignature = ""
        if let command { try await session.connect(profile: profile, sharing: command) }
        else if let host, let port { try await session.connect(profile: profile, host: host, port: port) }
        else { try await session.connect(profile: profile) }
        connected = true; changed?()
        let display: [String: Any] = ["DEVICE_ID": ownID, "DEVICE_TYPE": 5, "DISPLAY_NUMBER": 1, "LEFT": 0, "TOP": 0, "RIGHT": width, "BOTTOM": height, "ROTATION": 0]
        let version: [String: Any] = ["DEVICE_ID": ownID, "APP_VERSION": "0.5.19", "PROTOCOL_VERSION": 1.7, "MIN_PROTOCOL_VERSION": 0.0, "FEATURES": ["FEATURE_INPUT": 1, "FEATURE_WIFI_DIRECT": 0, "FEATURE_FOLDER_DND": 0, "FEATURE_MULTI_CONNECTION": 0, "FEATURE_ALIVE_CHECK": 1, "FEATURE_FOCUS_SEQ": 1, "FEATURE_CCP_SUPPORT": 0]]
        let information: [String: Any] = ["DEVICE_LIST": [display], "MC_VERSION_LIST": [version], "STATUS_LIST": [["DEVICE_ID": ownID, "STATUS": 0, "FDS_STATUS": 1]], "CONNECTION_TYPE": 0]
        ownInformation = information; informationResends = 0
        try await send("DEVICE_INFORMATION", information)
        try await send("NETWORK_INFORMATION", ["NETWORK_INFO": ["DEVICE_ID": ownID, "IS_MCC": 0]])
        status?("Multi Control session opened. Waiting for phone display information…")
    }
    private func send(_ name: String, _ parameters: [String: Any] = [:]) async throws {
        try await session.send(MultiControlWire.message(name, parameters: parameters, from: ownID))
    }
    private func handle(_ data: Data) async throws {
        guard jsonBuffer.count + data.count <= 1_048_576 else { throw ContinuityError.message("Multi Control message exceeded its size limit.") }
        jsonBuffer += data
        status?("Received Multi Control packet (\(data.count) bytes).")
        // Android SDK versions also deliver complete JSON without a trailing LF.
        if let object = (try? JSONSerialization.jsonObject(with: jsonBuffer)) as? [String: Any] {
            jsonBuffer = Data(); try await handleMessage(object); return
        }
        // Each application JSON message is newline-terminated, independent of TCP reads.
        while let end = jsonBuffer.firstIndex(of: 10) {
            let line = Data(jsonBuffer[..<end]); jsonBuffer = Data(jsonBuffer[(end + 1)...])
            guard !line.isEmpty, let value = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            try await handleMessage(value)
        }
    }
    private func handleMessage(_ value: [String: Any]) async throws {
            guard let name = value["MSG"] as? String else { return }
            let parameters = value["PARAM"] as? [String: Any] ?? [:]
            status?("Multi Control message: \(name).")
            switch name {
            case "MSG_ALIVE_CHECK": try await send("MSG_ACK_ALIVE_CHECK")
            case "DEVICE_INFORMATION", "DEVICE_LAYOUT_CHANGED":
                if let devices = parameters["DEVICE_LIST"] as? [[String: Any]],
                   let phone = devices.first(where: { ($0["DEVICE_TYPE"] as? Int) == 1 }) ?? devices.first(where: { ($0["DEVICE_ID"] as? String) != ownID }), let id = phone["DEVICE_ID"] as? String {
                    phoneID = id
                    phoneDisplay = phone
                    phoneSize = (max(1, (phone["RIGHT"] as? Int ?? 1080) - (phone["LEFT"] as? Int ?? 0)), max(1, (phone["BOTTOM"] as? Int ?? 2400) - (phone["TOP"] as? Int ?? 0)))
                    status?("Phone display received. Choose Control phone to send keyboard and mouse input."); changed?()
                    try await publishLayout()
                }
                // The tablet's service can start after our first DEVICE_INFORMATION and then
                // keeps asking for our layout; answer its repeats a few times (bounded).
                if name == "DEVICE_INFORMATION", !controlling, informationResends < 5, let information = ownInformation {
                    informationResends += 1
                    try await send("DEVICE_INFORMATION", information)
                    try await send("NETWORK_INFORMATION", ["NETWORK_INFO": ["DEVICE_ID": ownID, "IS_MCC": 0]])
                }
            case "FOCUS_DEVICE_CHANGED":
                if parameters["TARGET"] as? String == ownID {
                    // Test hook (`--multi-regain-focus`): a synthetic stream drifts to the display edge, where the
                    // device hands focus back; take it again and keep measuring.
                    if controlling, CommandLine.arguments.contains("--multi-regain-focus") { focusRegains += 1; status?("Focus returned by the device; taking it again (\(focusRegains))."); try await takeControl() }
                    else { focusReturned?(); await release(notifyPhone: false) }
                }
            case "REQUEST_DISCONNECTION": await disconnect(); status?("The phone ended Multi Control.")
            default: break
            }
    }
    public func configurePlacement(_ value: DevicePlacement) async throws {
        placement = value
        if isReadyForControl { try await publishLayout() }
    }
    private func publishLayout() async throws {
        guard !phoneID.isEmpty, let own = ownInformation?["DEVICE_LIST"] as? [[String: Any]] else { return }
        let origin = placement.remoteOrigin(hostWidth: hostSize.0, hostHeight: hostSize.1, remoteWidth: phoneSize.0, remoteHeight: phoneSize.1)
        let signature = "\(phoneID):\(hostSize):\(phoneSize):\(origin)"
        guard signature != lastLayoutSignature else { return }
        var remote = phoneDisplay
        remote["LEFT"] = origin.x; remote["TOP"] = origin.y
        remote["RIGHT"] = origin.x + phoneSize.0; remote["BOTTOM"] = origin.y + phoneSize.1
        try await send("DEVICE_LAYOUT_CHANGED", ["DEVICE_LIST": own + [remote]])
        lastLayoutSignature = signature
    }
    public func takeControl(entryFraction: Double? = nil) async throws {
        guard connected, !phoneID.isEmpty else { throw ContinuityError.message("Wait for the phone's display information first.") }
        sequence += 1
        let entry = entryFraction.map { placement.remoteEntry(width: phoneSize.0, height: phoneSize.1, fraction: $0) }
        try await send("FOCUS_DEVICE_CHANGED", ["TARGET": phoneID, "X": entry?.x ?? phoneSize.0 / 2, "Y": entry?.y ?? phoneSize.1 / 2, "SEQ": sequence])
        controlling = true; changed?()
    }
    /// True once the phone's display information arrived and control can be taken.
    public var isReadyForControl: Bool { connected && !phoneID.isEmpty }
    public var pointerTransportSummary: String { session.pointerTransportSummary }
    /// Thread-safe UDP movement path for the capture worker; nil when not connected.
    public var pointerSender: PointerSender? { session.pointerSender }
    /// Builds the worker-thread sender for keys, clicks, wheels and fallback
    /// movements; captures the session reference once, on the main actor.
    public func makeInputSender() -> ReliableInputSender {
        ReliableInputSender(gate: controlGate) { [session] data in try session.sendFromWorker(data) }
    }
    public func motion(x: Int, y: Int, wheel: Bool = false, elapsed: UInt8 = 0) async throws {
        guard controlling else { return }
        // Movement reaches this reliable path only when UDP is unavailable.
        if wheel { try await session.send(MultiControlWire.motion(x: x, y: y, wheel: true, elapsed: elapsed)) }
        else { for packet in MultiControlWire.pointerPackets(x: x, y: y, elapsed: elapsed) { try await session.send(packet) } }
    }
    public func key(_ scanCode: UInt16, down: Bool) async throws {
        guard controlling else { return }
        if down { pressedKeys.insert(scanCode) } else { pressedKeys.remove(scanCode) }
        try await session.send(MultiControlWire.key(scanCode: scanCode, down: down))
    }
    public func click(_ button: UInt8, down: Bool) async throws {
        guard controlling else { return }
        if down { pressedButtons.insert(button) } else { pressedButtons.remove(button) }
        try await session.send(MultiControlWire.click(button: button, down: down))
    }
    public func release(notifyPhone: Bool = true) async {
        let wasControlling = controlling
        controlling = false; released?(); changed?()
        let keys = pressedKeys, buttons = pressedButtons; pressedKeys = []; pressedButtons = []
        for key in keys { try? await session.send(MultiControlWire.key(scanCode: key, down: false)) }
        for button in buttons { try? await session.send(MultiControlWire.click(button: button, down: false)) }
        if notifyPhone, connected {
            if options.releaseMarker, wasControlling {
                let marker = MultiControlWire.focusReleaseMarker
                if session.pointerSender?.send(marker) != .sent { try? await session.send(marker) }
            }
            sequence += 1; try? await send("FOCUS_DEVICE_CHANGED", ["TARGET": ownID, "X": 0, "Y": 0, "SEQ": sequence])
        }
    }
    public func disconnect() async { await release(); session.disconnect(); connected = false; changed?() }
}
