import Foundation
import Network
import Security

/// Makes this Mac visible to Galaxy PCs on the local network.
///
/// Samsung's Windows service browses `_mcfds._tcp` and opens an account-authenticated
/// TCP connection to every service whose `DEVICE_ID` decrypts to a device of the
/// account (MDNSAgent.OnServiceUpdated). The record mirrors its own
/// CreateAdvertisementService: the instance name is a random 12-byte nonce in hex,
/// and `DEVICE_ID` is this Mac's Bluetooth identity sealed with the account key.
/// Each accepted connection becomes an ordinary clipboard session.
@MainActor public final class LANPresence: NSObject, NetServiceDelegate {
    private let profile: ContinuityProfile
    private var listener: NWListener?
    private var service: NetService?
    public private(set) var sessions: [ClipboardSession] = []
    public var status: ((String) -> Void)?
    public var trace: ((String) -> Void)?
    /// Called once per authenticated device, before its session starts reading.
    public var opened: ((ClipboardSession) -> Void)?
    public var changed: (() -> Void)?
    private var dialing = false

    public init(profile: ContinuityProfile) { self.profile = profile }

    /// PCs of the account with an open clipboard session.
    public var connectedPeers: [String] { sessions.compactMap(\.peerAddress) }

    public func start() throws {
        guard listener == nil else { return }
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let listener = try NWListener(using: NWParameters(tls: nil, tcp: tcp), on: .any)
        listener.newConnectionHandler = { [weak self] socket in Task { @MainActor in self?.accept(socket) } }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready: if let port = self.listener?.port?.rawValue { self.publish(port: port) }
                case .failed(let error): self.status?("LAN presence stopped: \(error.localizedDescription)"); self.stop()
                default: break
                }
            }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    public func stop() {
        service?.stop(); service = nil
        listener?.cancel(); listener = nil
        let open = sessions; sessions = []
        for session in open { session.stop() }
        changed?()
    }

    static func record(profile: ContinuityProfile, nonce: Data) throws -> (name: String, deviceID: String) {
        let identity = try MCFCrypto.seal(ContinuityProfile.addressBytes(profile.localBluetoothAddress), key: profile.accountKey, nonce: nonce)
        return (nonce.hexString.uppercased(), identity.hexString.uppercased())
    }

    private func publish(port: UInt16) {
        guard service == nil else { return }
        do {
            var nonce = Data(count: 12)
            guard nonce.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 12, $0.baseAddress!) }) == errSecSuccess else { throw ContinuityError.message("No secure random nonce.") }
            let record = try Self.record(profile: profile, nonce: nonce)
            let service = NetService(domain: "local.", type: "_mcfds._tcp.", name: record.name, port: Int32(port))
            guard service.setTXTRecord(NetService.data(fromTXTRecord: ["DEVICE_ID": Data(record.deviceID.utf8)])) else { throw ContinuityError.message("Could not set the service record.") }
            service.delegate = self
            service.publish()
            self.service = service
            trace?("LAN presence: advertising _mcfds._tcp on port \(port).")
        } catch { status?("LAN presence could not advertise: \(error.localizedDescription)") }
    }

    public nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        Task { @MainActor in self.status?("LAN presence could not advertise (\(errorDict)).") }
    }

    private func accept(_ socket: NWConnection) {
        let transport = MCFTransport(socket: socket)
        Task {
            var session: ClipboardSession?
            do {
                let timeout = Task { try? await Task.sleep(nanoseconds: 12_000_000_000); if !Task.isCancelled { transport.cancel() } }
                try await transport.connect()
                let responder = try MCFResponder(profile: profile, anyAccountPeer: true)
                try await transport.send(responder.reply(to: transport.receive()))
                try responder.finish(await transport.receive())
                timeout.cancel()
                guard let key = responder.sessionKey else { throw ContinuityError.message("Inbound account handshake failed.") }
                let opening = ClipboardSession(connection: transport, profile: profile)
                session = opening
                opened?(opening)
                try await opening.start(key: key, peer: responder.peerName, address: responder.peerAddress)
                sessions.append(opening); changed?()
                try await opening.run()
            } catch { trace?("LAN presence connection ended: \(error.localizedDescription)") }
            if let session { session.stop(); sessions.removeAll { $0 === session }; changed?() } else { transport.cancel() }
        }
    }

    /// Reconnects to Galaxy PCs at the endpoint each one last accepted. A PC that
    /// restarted listens on a new port; it is found again when it connects to this
    /// Mac's advertisement, or when an endpoint is supplied with `remember`.
    public func connectPCs() {
        guard !dialing, listener != nil else { return }
        dialing = true
        Task {
            defer { dialing = false }
            for peer in profile.peers where peer.deviceType?.lowercased() == "pc" && !connectedPeers.contains(peer.address) {
                guard let saved = UserDefaults.standard.string(forKey: "lan-endpoint-" + peer.address)?.split(separator: ":"),
                      saved.count == 2, let port = UInt16(saved[1]) else { continue }
                _ = await dial(String(saved[0]), port, peer)
            }
        }
    }

    /// Stores a PC's endpoint, for example one seen in a Samsung log or a manual setting.
    public static func remember(host: String, port: UInt16, peerAddress: String) {
        UserDefaults.standard.set("\(host):\(port)", forKey: "lan-endpoint-" + peerAddress)
    }

    private func dial(_ host: String, _ port: UInt16, _ peer: ContinuityProfile.Peer) async -> Bool {
        var target = profile; target.preferredPeerAddress = peer.address
        let session = ClipboardSession(connection: MCFTransport(host: host, port: port), profile: target)
        // Ports that are not Samsung's listener never answer the handshake.
        let deadline = Task { try? await Task.sleep(nanoseconds: 4_000_000_000); if !Task.isCancelled { session.connection.cancel() } }
        opened?(session)
        do { try await session.connect() } catch { deadline.cancel(); session.stop(); return false }
        deadline.cancel()
        UserDefaults.standard.set("\(host):\(port)", forKey: "lan-endpoint-" + peer.address)
        sessions.append(session); changed?()
        Task {
            do { try await session.run() } catch { trace?("LAN session with \(peer.name) ended: \(error.localizedDescription)") }
            session.stop(); sessions.removeAll { $0 === session }; changed?()
        }
        return true
    }
}
