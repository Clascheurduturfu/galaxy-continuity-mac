import Foundation

/// Upgrade a selected account-authenticated peer's command link to local TCP.
/// A handover offer is not a clipboard data socket and may omit its channel name.
@MainActor final class CommandHandover {
    private let profile: ContinuityProfile
    private weak var session: ClipboardSession?
    private var transport: MCFTransport?
    private var task: Task<Void, Never>?
    private var key = Data()
    private var sequence: UInt64 = 0
    var status: ((String) -> Void)?
    var isReady: Bool { !key.isEmpty }
    func applicationKey(_ appID: UInt8) throws -> Data { try FeatureProtocol.applicationKey(sessionKey: key, appID: appID) }
    init(profile: ContinuityProfile, session: ClipboardSession) { self.profile = profile; self.session = session }

    nonisolated static func details(_ data: Data, networks: [[String: Any]]) throws -> (String, UInt16, String?) {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ContinuityError.message("Invalid command handover offer.") }
        var channel: String?
        if let value = object["CN"], !(value is NSNull) {
            guard let text = value as? String, text.utf8.count <= 128,
                  text.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw ContinuityError.message("Invalid command handover channel.") }
            channel = text.isEmpty ? nil : text
        }
        let endpoint = try ClipboardTransfer.endpoint(object, networks: networks)
        return (endpoint.0, endpoint.1, channel)
    }
    func offer(_ payload: Data) throws {
        let endpoint = try Self.details(payload, networks: FeatureProtocol.localNetworks())
        guard task == nil else { return }
        let socket = MCFTransport(host: endpoint.0, port: endpoint.1); transport = socket
        task = Task { [weak self] in
            guard let self else { return }
            defer { socket.cancel(); key = Data(); transport = nil; task = nil }
            do {
                let deadline = Task { try? await Task.sleep(nanoseconds: 15_000_000_000); if !Task.isCancelled { socket.cancel() } }
                let auth: MCFHandshake
                do { auth = try await socket.authenticate(profile: profile, channel: endpoint.2); deadline.cancel() }
                catch { deadline.cancel(); throw error }
                guard let negotiated = auth.sessionKey else { throw ContinuityError.message("No Wi-Fi command key.") }
                key = negotiated; status?("Samsung Wi-Fi command handover authenticated.")
                while !Task.isCancelled {
                    let packet = try await socket.receive()
                    let inner = try MCFCommand(data: MCFCrypto.cbc(packet.payload, key: negotiated, encrypt: false))
                    try await session?.handleIncoming(handler: packet.handler, command: inner, context: packet.advPayload) { [weak self] handler, response in
                        guard let self else { throw CancellationError() }
                        try await self.send(handler: handler, command: response, context: Data())
                    }
                }
            } catch { if !Task.isCancelled { status?("Wi-Fi command handover: " + error.localizedDescription) } }
        }
    }
    func send(handler: UInt64, command: MCFCommand, context: Data) async throws {
        guard let transport, !key.isEmpty else { throw ContinuityError.message("The Wi-Fi command connection is not authenticated.") }
        sequence += 1
        try await transport.send(MCFPacket(handler: handler, sequence: sequence, payload: MCFCrypto.cbc(command.encoded, key: key, encrypt: true), advPayload: context, accountRevision: profile.revision))
    }
    func stop() { task?.cancel(); transport?.cancel(); task = nil; transport = nil; key = Data() }
}
