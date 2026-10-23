import Foundation
import CryptoKit

/// Account-authenticated inbound command channel, for phone-initiated Wi-Fi setup.
final class MCFResponder {
    private let profile: ContinuityProfile
    private let privateKey = P256.KeyAgreement.PrivateKey()
    private var pendingKey: Data?
    private(set) var sessionKey: Data?
    private(set) var requestedChannel: String?
    private(set) var peerName: String?
    private(set) var peerAddress: String?
    /// LAN presence accepts any device of the account, not only the selected phone.
    private let anyAccountPeer: Bool
    init(profile: ContinuityProfile, anyAccountPeer: Bool = false) throws { try profile.validate(); self.profile = profile; self.anyAccountPeer = anyAccountPeer }
    private func fields(_ packet: MCFPacket) throws -> [Int: [ProtoWire.Value]] {
        guard packet.handler == 0, packet.authType == 1 else { throw ContinuityError.message("Missing account authentication on inbound Wi-Fi.") }
        return try ProtoWire.fields(MCFCrypto.open(packet.payload, key: profile.accountKey, nonce: packet.iv.isEmpty ? Data(repeating: 0, count: 12) : packet.iv))
    }
    func reply(to initial: MCFPacket) throws -> MCFPacket {
        let fields = try fields(initial), address = ProtoWire.bytes(fields, 3)
        let channel = ProtoWire.bytes(fields, 6)
        if !channel.isEmpty {
            guard channel.count <= 128, let text = String(data: channel, encoding: .utf8), text.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
                throw ContinuityError.message("Invalid authenticated transfer channel name.")
            }
            requestedChannel = text
        }
        let peer = try profile.peers.first(where: { try ContinuityProfile.addressBytes($0.address) == address })
        guard ProtoWire.number(fields, 1) == 1, peer != nil,
              try anyAccountPeer || profile.preferredPeerAddress.map({ try ContinuityProfile.addressBytes($0) == address }) ?? true else {
            throw ContinuityError.message("An unselected Samsung device attempted a Wi-Fi connection.")
        }
        peerName = peer?.name; peerAddress = peer?.address
        let remotePublic = ProtoWire.bytes(fields, 4)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(derRepresentation: remotePublic))
        pendingKey = shared.withUnsafeBytes { Data($0) }
        var body = ProtoWire.number(1, 2) + ProtoWire.number(2, 0)
        body += ProtoWire.bytes(3, try ContinuityProfile.addressBytes(profile.localBluetoothAddress))
        body += ProtoWire.bytes(4, privateKey.publicKey.derRepresentation)
        body += ProtoWire.bytes(5, Data(SHA256.hash(data: remotePublic).prefix(6)))
        body += ProtoWire.number(7, 1) + ProtoWire.number(8, profile.revision)
        let nonce = Data(repeating: 0, count: 12)
        return MCFPacket(payload: try MCFCrypto.seal(body, key: profile.accountKey, nonce: nonce), authType: 1, iv: nonce)
    }
    func finish(_ packet: MCFPacket) throws {
        let fields = try fields(packet)
        guard pendingKey != nil, ProtoWire.number(fields, 1) == 3,
              ProtoWire.bytes(fields, 5) == Data(SHA256.hash(data: privateKey.publicKey.derRepresentation).prefix(6)) else {
            throw ContinuityError.message("Invalid inbound Wi-Fi authentication proof.")
        }
        sessionKey = pendingKey; pendingKey = nil
    }
}
