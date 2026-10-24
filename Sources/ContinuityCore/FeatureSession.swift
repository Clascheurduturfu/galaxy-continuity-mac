import Foundation
import CryptoKit
import Network
import Darwin
import CoreWLAN

public enum FeatureProtocol {
    public static func applicationKey(sessionKey: Data, appID: UInt8) throws -> Data {
        guard sessionKey.count == 32 else { throw ContinuityError.message("Invalid feature session key.") }
        var material = sessionKey; material[0] = material[0] &+ appID
        return Data(SHA256.hash(data: material))
    }
    static func connectionRequest(appID: UInt8, address: String, port: UInt16, networks: [[String: Any]]) throws -> Data {
        Data([appID, 12, 30, 21]) + (try JSONSerialization.data(withJSONObject: [
            "ID": address, "IP": "", "PT": Int(port), "SKCF": false,
            "ARRAY": networks, "NET_ARRAY": []
        ]))
    }
    static func endpoint(_ payload: Data, appID: UInt8) throws -> (String, UInt16) {
        try validateResponse(payload, appID: appID)
        let bytes = Array(payload)
        guard let json = try JSONSerialization.jsonObject(with: Data(bytes.dropFirst(3))) as? [String: Any],
              let host = json["IP"] as? String, IPv4Address(host) != nil,
              let raw = json["PT"] as? Int, let port = UInt16(exactly: raw), port > 0 else {
            throw ContinuityError.message("Samsung returned an invalid feature address.")
        }
        return (host, port)
    }
    static func validateResponse(_ payload: Data, appID: UInt8) throws {
        let bytes = Array(payload)
        guard bytes.count >= 3, bytes[0] == appID, bytes[1] == 12 else { throw ContinuityError.message("Invalid feature response.") }
        guard bytes[2] == 1 else {
            let reasons: [UInt8: String] = [2: "phone service unavailable", 3: "phone busy", 4: "feature session unavailable", 5: "network unavailable", 6: "devices on different networks", 7: "device not found", 8: "already connected", 9: "another connection active", 10: "network restricted", 12: "connection unavailable", 13: "phone location permission required"]
            throw ContinuityError.message("Samsung rejected the feature session: \(reasons[bytes[2]] ?? "reason \(bytes[2])").")
        }
    }
    static func networkAddress(_ ip: String, mask: String) -> String? {
        var address = in_addr(), netmask = in_addr()
        guard inet_pton(AF_INET, ip, &address) == 1, inet_pton(AF_INET, mask, &netmask) == 1 else { return nil }
        var network = in_addr(s_addr: address.s_addr & netmask.s_addr)
        var storage = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &network, &storage, socklen_t(storage.count)) != nil else { return nil }
        return String(cString: storage)
    }
    /// Type and network only, for diagnostics; never the Mac's own address.
    static func networkSummary(_ networks: [[String: Any]]) -> String {
        networks.map { "\($0["TYPE"] as? String ?? "?") \($0["SUBNET"] as? String ?? "?")/\($0["MASK"] as? String ?? "?")" }.joined(separator: ", ")
    }
    static func localNetworks(commandPort: UInt16 = 0) throws -> [[String: Any]] {
        let wifi = CWWiFiClient.shared().interface()
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { throw ContinuityError.message("Could not read Mac network addresses.") }
        defer { freeifaddrs(pointer) }
        var result: [[String: Any]] = []
        var cursor = pointer
        while let value = cursor?.pointee {
            defer { cursor = value.ifa_next }
            let name = String(cString: value.ifa_name)
            guard name.hasPrefix("en"), value.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = value.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET), let mask = value.ifa_netmask else { continue }
            func string(_ address: UnsafeMutablePointer<sockaddr>) -> String {
                var storage = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(address, socklen_t(address.pointee.sa_len), &storage, socklen_t(storage.count), nil, 0, NI_NUMERICHOST)
                return String(cString: storage)
            }
            let isWiFi = wifi?.interfaceName == name
            var mac = ""
            var link = pointer
            while let entry = link?.pointee {
                defer { link = entry.ifa_next }
                guard String(cString: entry.ifa_name) == name, let addr = entry.ifa_addr,
                      addr.pointee.sa_family == sa_family_t(AF_LINK) else { continue }
                let record = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_dl.self).pointee
                if record.sdl_alen == 6 {
                    mac = withUnsafeBytes(of: record.sdl_data) { bytes in
                        bytes.dropFirst(Int(record.sdl_nlen)).prefix(6).map { String(format: "%02x", $0) }.joined(separator: ":")
                    }
                }
            }
            let bssid = isWiFi ? wifi?.bssid() ?? "" : ""
            // Samsung matches peers by BSSID, else by SUBNET as the network
            // address (IP & mask), not the mask. MASK is only used locally.
            let ip = string(address), maskText = string(mask)
            result.append(["TYPE": isWiFi ? "wlan" : "ethernet", "ID": isWiFi ? bssid : mac, "IP": ip, "LPT": Int(commandPort), "SSID": isWiFi ? wifi?.ssid() ?? "" : "", "SUBNET": networkAddress(ip, mask: maskText) ?? "", "MASK": maskText, "MAC": mac, "FRQ": 0])
        }
        guard !result.isEmpty else { throw ContinuityError.message("Connect the Mac and phone to the same Wi-Fi network first.") }
        return result
    }
}

/// The SDK's inner packet reuses protobuf fields 1=type, 2=id, 3=payload.
/// Authentication uses IV-prefixed CBC; established ET=0 uses a fixed negotiated IV.
@MainActor final class FeatureChannel {
    let transport: MCFTransport
    let key: Data
    private var iv = Data()
    /// UDP socket, packet sequence and thread-safe pointer send path.
    let pointer = PointerSender()
    private var localUDPPort: UInt16 = 0
    private let host: String?
    init(transport: MCFTransport, key: Data, host: String? = nil) { self.transport = transport; self.key = key; self.host = host }
    func close() { transport.cancel(); pointer.close() }
    private func openDatagrams() {
        guard host != nil else { return }
        localUDPPort = pointer.open(ipTOS: PointerOptions.load().ipTOS) ?? 0
    }
    private func receiveAuth(_ type: UInt64) async throws -> [String: Any] {
        let packet = try await transport.receive()
        guard packet.handler == type, let json = try JSONSerialization.jsonObject(with: MCFCrypto.cbc(packet.payload, key: key, encrypt: false)) as? [String: Any] else { throw ContinuityError.message("Invalid feature authentication packet.") }
        return json
    }
    private func sendAuth(_ type: UInt64, _ value: [String: Any]) async throws {
        let payload = try MCFCrypto.cbc(JSONSerialization.data(withJSONObject: value), key: key, encrypt: true)
        try await transport.send(MCFPacket(handler: type, payload: payload))
    }
    func authenticate(accepting: Bool = false) async throws {
        let timeout = Task { try? await Task.sleep(nanoseconds: 12_000_000_000); if !Task.isCancelled { self.close() } }
        defer { timeout.cancel() }
        try await transport.connect()
        openDatagrams()
        let localNonce = try ContinuityAuthCrypto.random(16)
        if accepting {
            try await sendAuth(3, ["NE": localNonce.hexString.uppercased()])
            let ack = try await receiveAuth(4)
            guard let nonceText = ack["NE"] as? String, let nonce = Data(hex: nonceText), nonce.count == 16,
                  Data(hex: ack["HNE"] as? String ?? "") == Data(SHA256.hash(data: localNonce)),
                  let traffic = ack["TT"] as? Int, [1100, 1101, 1102].contains(traffic),
                  ack["DT"] as? Int == 11, [0, 1].contains(ack["ET"] as? Int ?? -1) else {
                throw ContinuityError.message("Inbound feature handshake rejected: traffic \(ack["TT"] as? Int ?? -1), data \(ack["DT"] as? Int ?? -1), encryption \(ack["ET"] as? Int ?? -1).")
            }
            iv = nonce
            try await sendAuth(5, ["HNE": Data(SHA256.hash(data: nonce)).hexString.uppercased(), "LUP": 0, "TT": traffic, "DT": 11, "ET": 0, "ST": 21])
        } else {
            let initial = try await receiveAuth(3)
            guard let text = initial["NE"] as? String, let nonce = Data(hex: text), nonce.count == 16 else { throw ContinuityError.message("Invalid feature authentication nonce.") }
            try await sendAuth(4, ["NE": localNonce.hexString.uppercased(), "HNE": Data(SHA256.hash(data: nonce)).hexString.uppercased(), "LUP": Int(localUDPPort), "TT": 1102, "DT": 11, "ET": 0, "ST": 21])
            let finish = try await receiveAuth(5)
            guard Data(hex: finish["HNE"] as? String ?? "") == Data(SHA256.hash(data: localNonce)) else { throw ContinuityError.message("The phone's feature nonce proof did not match.") }
            guard finish["TT"] as? Int == 1102, finish["DT"] as? Int == 11,
                  [0, 1].contains(finish["ET"] as? Int ?? -1) else {
                throw ContinuityError.message("Unsupported feature mode: traffic \(finish["TT"] as? Int ?? -1), data \(finish["DT"] as? Int ?? -1), encryption \(finish["ET"] as? Int ?? -1).")
            }
            // Samsung advertises its maximum ET in FIN. Our ACK advertised 0,
            // so both ends use min(local maximum, peer maximum) = CBC (0).
            iv = localNonce
            if let host, let raw = finish["LUP"] as? Int, let port = UInt16(exactly: raw), port > 0, localUDPPort > 0 {
                var endpoint = sockaddr_in(); endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); endpoint.sin_family = sa_family_t(AF_INET); endpoint.sin_port = port.bigEndian
                if inet_pton(AF_INET, host, &endpoint.sin_addr) == 1 { pointer.connect(remote: endpoint, key: key, iv: iv) }
            }
        }
    }
    func send(_ data: Data) async throws {
        guard iv.count == 16, data.count <= 1_048_576 else { throw ContinuityError.message("Feature channel is not ready or the message is too large.") }
        let sequence = pointer.nextSequence()
        // Use the existing CBC primitive with the negotiated IV for decryption,
        // and a fixed-IV variant for the SDK's ET=0 data packets.
        let payload = try MCFCrypto.cbcFixed(data, key: key, iv: iv)
        try await transport.send(MCFPacket(handler: 11, sequence: sequence, payload: payload))
    }
    /// Synchronous `send` for the pointer worker thread (keys, clicks, wheels,
    /// TCP-fallback movements): same framing, no actor hop.
    func sendBlocking(_ data: Data) throws {
        guard iv.count == 16, data.count <= 1_048_576 else { throw ContinuityError.message("Feature channel is not ready or the message is too large.") }
        let sequence = pointer.nextSequence()
        let payload = try MCFCrypto.cbcFixed(data, key: key, iv: iv)
        try transport.sendFrameBlocking(MCFPacket(handler: 11, sequence: sequence, payload: payload).encoded)
    }
    func receive() async throws -> Data {
        while true {
            let packet = try await transport.receive()
            guard packet.handler == 11 else { throw ContinuityError.message("Unsupported feature packet type \(packet.handler).") }
            return try MCFCrypto.cbc(iv + packet.payload, key: key, encrypt: false)
        }
    }
}

/// Lock-protected holder for the primary feature channel, shared between the
/// main actor (connection lifecycle) and the pointer worker (input sends).
final class PrimaryChannelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: FeatureChannel?
    func get() -> FeatureChannel? { lock.lock(); defer { lock.unlock() }; return channel }
    func set(_ value: FeatureChannel?) { lock.lock(); channel = value; lock.unlock() }
    /// Serialized worker write: a disconnect setting the channel either waits
    /// for the in-flight frame or makes this throw — it can never interleave.
    func send(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard let channel else { throw ContinuityError.message("The feature is not connected.") }
        try channel.sendBlocking(data)
    }
}

@MainActor public final class FeatureSession {
    public let appID: UInt8
    public var status: ((String) -> Void)?
    public var received: ((Data) -> Void)?
    public var ready: (() -> Void)?
    public private(set) var peerIP: String?
    private var command: ClipboardSession?
    private var ownsCommand = true
    private var commandHandlerToken: UUID?
    private var commandLoop: Task<Void, Never>?
    private var listener: NWListener?
    private var commandListener: NWListener?
    private var inboundCommands: [MCFTransport] = []
    private var channels: [FeatureChannel] = []
    private var readers: [Task<Void, Never>] = []
    private let workerChannel = PrimaryChannelBox()
    /// The authenticated feature channel. Stored behind a lock (`PrimaryChannelBox`)
    /// so the pointer worker can read it; see `sendFromWorker`.
    private var primary: FeatureChannel? {
        get { workerChannel.get() }
        set { workerChannel.set(newValue) }
    }
    private var coreConnected = false
    public var isConnected: Bool { primary != nil || coreConnected }
    private var appKey = Data()
    private var response: CheckedContinuation<Data, Error>?
    private var generation = UUID()
    public var pointerTransportSummary: String { primary?.pointer.summary ?? "disconnected" }
    /// Thread-safe UDP pointer path of the established feature channel.
    public var pointerSender: PointerSender? { primary?.pointer }
    /// Synchronous reliable-channel send for the capture worker — keys, clicks,
    /// wheels and TCP-fallback movements leave without an actor hop, like the
    /// Book's hook-thread sends. Serialized with channel changes, so a
    /// concurrent disconnect either waits for the frame or fails the send.
    public nonisolated func sendFromWorker(_ data: Data) throws { try workerChannel.send(data) }
    public init(appID: UInt8) { self.appID = appID }
    public func connect(profile: ContinuityProfile) async throws {
        try await connect(command: ClipboardSession(connection: try BLEMCFTransport(profile: profile), profile: profile), profile: profile)
    }
    public func connect(profile: ContinuityProfile, host: String, port: UInt16) async throws {
        try await connect(command: ClipboardSession(connection: MCFTransport(host: host, port: port), profile: profile), profile: profile)
    }
    public func connect(profile: ContinuityProfile, sharing command: ClipboardSession) async throws {
        try await connect(command: command, profile: profile, ownsCommand: false)
    }
    func acceptClipboardRequest(profile: ContinuityProfile, sharing command: ClipboardSession) async throws {
        guard appID == 102 else { throw ContinuityError.message("Unsolicited feature is not supported.") }
        try await connect(command: command, profile: profile, ownsCommand: false, accepting: true)
    }
    private func connect(command: ClipboardSession, profile: ContinuityProfile, ownsCommand: Bool = true, accepting: Bool = false) async throws {
        disconnect(); let attempt = UUID(); generation = attempt
        self.command = command
        self.ownsCommand = ownsCommand
        if ownsCommand {
            command.status = { [weak self] in self?.status?($0) }
            command.trace = { [weak self] in self?.status?($0) }
        }
        commandHandlerToken = command.addClientHandler { [weak self] packet in
            guard let self, packet.payload.first == appID else { return }
            if packet.id == 1, packet.type == 2 { let pending = response; response = nil; pending?.resume(returning: packet.payload) }
            if packet.id == 2 { disconnect(); status?("The phone ended the feature session.") }
        }
        let deadline = Task { try? await Task.sleep(nanoseconds: 45_000_000_000); if !Task.isCancelled { self.disconnect(); self.status?("Feature session timed out. Check the phone's feature toggle and permission prompt.") } }
        defer { deadline.cancel() }
        do {
            if ownsCommand { try await command.connect() }; appKey = try command.applicationKey(appID)
            if ownsCommand { commandLoop = Task { [weak self] in
                do { try await command.run() } catch { guard let self, generation == attempt else { return }; disconnect(); status?(error.localizedDescription) }
            } }
            let control = try NWListener(using: .tcp, on: .any); commandListener = control
            control.newConnectionHandler = { [weak self] socket in
                Task { @MainActor in
                    guard let self, self.generation == attempt, self.inboundCommands.count < 3 else { socket.cancel(); return }
                    let transport = MCFTransport(socket: socket); self.inboundCommands.append(transport)
                    self.readers.append(Task { [weak self] in
                        guard let self else { return }
                        do { try await self.acceptCommand(transport, profile: profile, attempt: attempt) }
                        catch { transport.cancel(); self.status?("Inbound account connection: " + error.localizedDescription) }
                    })
                }
            }
            let commandPort = try await start(control)
            if appID == 102 {
                // Clipboard is an internal core session, without an external
                // SDK feature socket. Its file bytes use a separate data channel.
                let networks = try FeatureProtocol.localNetworks(commandPort: commandPort)
                if accepting {
                    let body = try JSONSerialization.data(withJSONObject: ["ID": profile.localBluetoothAddress, "IP": "", "PT": 0, "ARRAY": networks])
                    try await command.sendClientCommand(MCFCommand(id: 1, type: 2, payload: Data([102, 12, 1]) + body))
                } else {
                    let payload = try FeatureProtocol.connectionRequest(appID: 102, address: profile.localBluetoothAddress, port: 0, networks: networks)
                    let reply = try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Data, Error>) in
                        response = pending
                        Task { do { try await command.sendClientCommand(MCFCommand(id: 1, type: 1, payload: payload)) } catch { let pending = self.response; self.response = nil; pending?.resume(throwing: error) } }
                    }
                    try FeatureProtocol.validateResponse(reply, appID: 102)
                }
                try await command.waitForWifiCommand()
                guard generation == attempt else { throw CancellationError() }
                coreConnected = true; status?("Samsung clipboard core session connected; no SDK socket required."); ready?(); return
            }
            let listener = try NWListener(using: .tcp, on: .any); self.listener = listener
            listener.newConnectionHandler = { [weak self] socket in
                Task { @MainActor in
                    guard let self, self.generation == attempt, self.channels.count < 4 else { socket.cancel(); return }
                    let channel = FeatureChannel(transport: MCFTransport(socket: socket), key: self.appKey)
                    self.channels.append(channel)
                    let reader = Task { [weak self] in
                        do {
                            try await channel.authenticate(accepting: true)
                            if accepting, let self, self.generation == attempt {
                                self.primary = channel
                                let pending = self.response; self.response = nil; pending?.resume(returning: Data())
                            }
                            try await self?.read(channel, generation: attempt)
                        }
                        catch { channel.close(); self?.status?("Incoming feature channel: " + error.localizedDescription) }
                    }
                    self.readers.append(reader)
                }
            }
            try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
                var finished = false
                listener.stateUpdateHandler = { state in
                    Task { @MainActor in
                        guard !finished else { return }
                        switch state {
                        case .ready: finished = true; pending.resume()
                        case .failed(let error): finished = true; pending.resume(throwing: error)
                        case .cancelled: finished = true; pending.resume(throwing: CancellationError())
                        default: break
                        }
                    }
                }
                listener.start(queue: .main)
            }
            guard let sdkPort = listener.port?.rawValue else { throw ContinuityError.message("Could not open a local feature port.") }
            if accepting {
                let networks = try FeatureProtocol.localNetworks(commandPort: commandPort)
                guard let network = networks.first(where: { $0["TYPE"] as? String == "wlan" }) ?? networks.first,
                      let ip = network["IP"] as? String else { throw ContinuityError.message("No local Wi-Fi address for clipboard.") }
                let body = try JSONSerialization.data(withJSONObject: ["ID": profile.localBluetoothAddress, "IP": ip, "PT": Int(sdkPort), "ARRAY": networks])
                let _: Data = try await withCheckedThrowingContinuation { pending in
                    response = pending
                    Task {
                        do { try await command.sendClientCommand(MCFCommand(id: 1, type: 2, payload: Data([appID, 12, 1]) + body)) }
                        catch { let pending = self.response; self.response = nil; pending?.resume(throwing: error) }
                    }
                }
                guard generation == attempt, primary != nil else { throw CancellationError() }
                status?("Phone-initiated clipboard Wi-Fi session authenticated."); ready?(); return
            }
            let payload = try FeatureProtocol.connectionRequest(appID: appID, address: profile.localBluetoothAddress, port: sdkPort, networks: FeatureProtocol.localNetworks(commandPort: commandPort))
            status?("Requesting Samsung feature \(appID) over the local network…")
            let reply = try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Data, Error>) in
                response = pending
                Task { do { try await command.sendClientCommand(MCFCommand(id: 1, type: 1, payload: payload)) } catch { let pending = self.response; self.response = nil; pending?.resume(throwing: error) } }
            }
            let (ip, sdkRemotePort) = try FeatureProtocol.endpoint(reply, appID: appID)
            peerIP = ip
            guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
            let channel = FeatureChannel(transport: MCFTransport(host: ip, port: sdkRemotePort), key: appKey, host: ip)
            channels.append(channel)
            try await channel.authenticate()
            guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
            primary = channel
            if !channel.pointer.setupSummary.isEmpty { status?(channel.pointer.setupSummary) }
            readers.append(Task { [weak self] in
                do { try await self?.read(channel, generation: attempt) }
                catch { guard let self, generation == attempt else { return }; disconnect(); status?(error.localizedDescription) }
            })
            status?("Samsung feature \(appID) authenticated."); ready?()
        } catch { if generation == attempt { disconnect() }; throw error }
    }
    private func start(_ listener: NWListener) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
            var done = false
            listener.stateUpdateHandler = { state in Task { @MainActor in
                guard !done else { return }
                switch state {
                case .ready: done = true; pending.resume()
                case .failed(let error): done = true; pending.resume(throwing: error)
                case .cancelled: done = true; pending.resume(throwing: CancellationError())
                default: break
                }
            } }
            listener.start(queue: .main)
        }
        guard let port = listener.port?.rawValue else { throw ContinuityError.message("Could not open a local connection port.") }; return port
    }
    private func acceptCommand(_ transport: MCFTransport, profile: ContinuityProfile, attempt: UUID) async throws {
        let timeout = Task { try? await Task.sleep(nanoseconds: 12_000_000_000); if !Task.isCancelled { transport.cancel() } }
        defer { timeout.cancel() }
        try await transport.connect()
        let responder = try MCFResponder(profile: profile)
        try await transport.send(responder.reply(to: transport.receive()))
        try responder.finish(await transport.receive())
        timeout.cancel()
        guard let key = responder.sessionKey else { throw ContinuityError.message("Inbound account handshake failed.") }
        status?("Phone opened an authenticated Wi-Fi command channel.")
        var sequence: UInt64 = 0
        func reply(_ handler: UInt64, _ inner: MCFCommand) async throws {
            sequence += 1
            try await transport.send(MCFPacket(handler: handler, sequence: sequence, payload: MCFCrypto.cbc(inner.encoded, key: key, encrypt: true), accountRevision: profile.revision))
        }
        while !Task.isCancelled, generation == attempt {
            let packet = try await transport.receive()
            let inner = try MCFCommand(data: MCFCrypto.cbc(packet.payload, key: key, encrypt: false))
            if packet.handler != 100 { try await command?.handleIncoming(handler: packet.handler, command: inner, context: packet.advPayload, reply: reply) }
            if packet.handler == 100, [1, 2].contains(inner.id) { try await command?.handleIncoming(handler: packet.handler, command: inner, context: packet.advPayload, reply: reply); continue }
            if packet.handler == 100, inner.type == 1 {
                var body = Data()
                if [1, 2].contains(inner.id) {
                    let json = (try? JSONSerialization.jsonObject(with: inner.payload)) as? [String: Any]
                    body = try JSONSerialization.data(withJSONObject: ["RC": 2, "CN": json?["CN"] as? String ?? ""])
                }
                sequence += 1
                try await transport.send(MCFPacket(handler: 100, sequence: sequence, payload: MCFCrypto.cbc(MCFCommand(id: inner.id, type: 2, payload: body).encoded, key: key, encrypt: true), accountRevision: profile.revision))
            }
        }
    }
    private func read(_ channel: FeatureChannel, generation attempt: UUID) async throws {
        while !Task.isCancelled, generation == attempt { let data = try await channel.receive(); received?(data) }
    }
    public func send(_ data: Data) async throws {
        guard let primary else { throw ContinuityError.message("The feature is not connected.") }
        try await primary.send(data)
    }
    public func disconnect() {
        generation = UUID()
        let pending = response; response = nil; pending?.resume(throwing: CancellationError())
        commandLoop?.cancel(); commandLoop = nil
        if let commandHandlerToken { command?.removeClientHandler(commandHandlerToken) }; commandHandlerToken = nil
        if ownsCommand { command?.stop() }; command = nil
        listener?.cancel(); listener = nil
        commandListener?.cancel(); commandListener = nil
        inboundCommands.forEach { $0.cancel() }; inboundCommands = []
        readers.forEach { $0.cancel() }; readers = []
        channels.forEach { $0.close() }; channels = []; primary = nil; coreConnected = false; appKey = Data(); peerIP = nil
    }
}
