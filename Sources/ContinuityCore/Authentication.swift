import Foundation
import CryptoKit
import CommonCrypto
import Security

public struct ContinuityProfile: Codable {
    public var format: String
    public var accountKey: Data
    public var localBluetoothAddress: String
    public var peers: [Peer]
    public var revision: UInt64
    public var expiresAt: Int64
    public var borrowedIdentity: Bool
    public var accountFingerprint: Data?
    public var preferredPeerAddress: String?
    public struct Peer: Codable {
        public var address: String
        public var name: String
        public var deviceType: String?
        public var model: String?
        public init(address: String, name: String, deviceType: String? = nil, model: String? = nil) {
            self.address = address
            self.name = name
            self.deviceType = deviceType
            self.model = model
        }
    }
    public init(
        format: String = "galaxy-continuity-profile-v1",
        accountKey: Data,
        localBluetoothAddress: String,
        peers: [Peer],
        revision: UInt64 = 1,
        expiresAt: Int64,
        borrowedIdentity: Bool = false,
        accountFingerprint: Data? = nil,
        preferredPeerAddress: String? = nil
    ) {
        self.format = format
        self.accountKey = accountKey
        self.localBluetoothAddress = localBluetoothAddress
        self.peers = peers
        self.revision = revision
        self.expiresAt = expiresAt
        self.borrowedIdentity = borrowedIdentity
        self.accountFingerprint = accountFingerprint
        self.preferredPeerAddress = preferredPeerAddress
    }
    public func validate() throws {
        guard format == "galaxy-continuity-profile-v1", accountKey.count == 32,
              try Self.addressBytes(localBluetoothAddress).count == 6, !peers.isEmpty,
              expiresAt > Int64(Date().timeIntervalSince1970 * 1000) else { throw ContinuityError.message("The continuity profile is invalid or expired. Export a fresh profile from Galaxy Connect.") }
        for peer in peers { _ = try Self.addressBytes(peer.address) }
    }
    public static func addressBytes(_ text: String) throws -> Data {
        let compact = text.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        guard compact.count == 12, compact.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw ContinuityError.message("Invalid Bluetooth identity.") }
        var bytes = Data(); var index = compact.startIndex
        while index < compact.endIndex { let end = compact.index(index, offsetBy: 2); bytes.append(UInt8(compact[index..<end], radix: 16)!); index = end }
        return bytes
    }
}

public enum MCFCrypto {
    static func cbcFixed(_ data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 32, iv.count == 16 else { throw ContinuityError.message("Invalid feature encryption parameters.") }
        var output = Data(count: data.count + kCCBlockSizeAES128); let capacity = output.count; var written = 0
        let result = key.withUnsafeBytes { secret in iv.withUnsafeBytes { vector in data.withUnsafeBytes { input in output.withUnsafeMutableBytes { buffer in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), secret.baseAddress, key.count, vector.baseAddress, input.baseAddress, data.count, buffer.baseAddress, capacity, &written)
        } } } }
        guard result == kCCSuccess else { throw ContinuityError.message("Feature encryption failed.") }
        output.count = written; return output
    }
    public static func seal(_ plain: Data, key: Data, nonce: Data) throws -> Data {
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce))
        return box.ciphertext + box.tag
    }
    public static func open(_ sealed: Data, key: Data, nonce: Data) throws -> Data {
        guard sealed.count >= 16, key.count == 32, nonce.count == 12 else { throw ContinuityError.message("Invalid authenticated ciphertext.") }
        return try AES.GCM.open(AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16)), using: SymmetricKey(data: key))
    }
    public static func cbc(_ data: Data, key: Data, encrypt: Bool) throws -> Data {
        guard key.count == 32, encrypt || data.count >= 32 else { throw ContinuityError.message("Invalid session ciphertext.") }
        let iv: Data
        if encrypt {
            var random = Data(count: 16)
            let status = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            guard status == errSecSuccess else { throw ContinuityError.message("Could not create a session nonce.") }; iv = random
        } else { iv = data.prefix(16) }
        let input = encrypt ? data : Data(data.dropFirst(16))
        var output = Data(count: input.count + kCCBlockSizeAES128); let capacity = output.count; var written = 0
        let status = key.withUnsafeBytes { keyBytes in iv.withUnsafeBytes { ivBytes in input.withUnsafeBytes { inputBytes in output.withUnsafeMutableBytes { outputBytes in
            CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, key.count, ivBytes.baseAddress, inputBytes.baseAddress, input.count, outputBytes.baseAddress, capacity, &written)
        } } } }
        guard status == kCCSuccess else { throw ContinuityError.message("Session decryption failed (\(status)).") }
        output.count = written; return encrypt ? iv + output : output
    }
}

public final class MCFHandshake {
    private let profile: ContinuityProfile
    private let privateKey = P256.KeyAgreement.PrivateKey()
    public private(set) var sessionKey: Data?
    public private(set) var authenticatedPeer: String?
    public private(set) var authenticatedAddress: String?
    public init(profile: ContinuityProfile) throws { try profile.validate(); self.profile = profile }
    private func packet(_ body: Data) throws -> MCFPacket {
        // Account authentication in this shipped version uses an all-zero GCM
        // nonce. This is protocol compatibility, not a recommended new design.
        let nonce = Data(repeating: 0, count: 12)
        return MCFPacket(payload: try MCFCrypto.seal(body, key: profile.accountKey, nonce: nonce), authType: 1, iv: nonce)
    }
    public func initiate(channel: String? = nil) throws -> MCFPacket {
        var body = ProtoWire.number(1, 1) + ProtoWire.bytes(3, try ContinuityProfile.addressBytes(profile.localBluetoothAddress))
        body += ProtoWire.bytes(4, privateKey.publicKey.derRepresentation) + ProtoWire.number(7, 1) + ProtoWire.number(8, profile.revision)
        if let channel { body += ProtoWire.bytes(6, Data(channel.utf8)) }
        return try packet(body)
    }
    public func finish(_ reply: MCFPacket) throws -> MCFPacket {
        guard reply.handler == 0, reply.authType == 1 else { throw ContinuityError.message("Peer did not return account authentication.") }
        let nonce = reply.iv.isEmpty ? Data(repeating: 0, count: 12) : reply.iv
        let f = try ProtoWire.fields(MCFCrypto.open(reply.payload, key: profile.accountKey, nonce: nonce))
        guard ProtoWire.number(f, 1) == 2, ProtoWire.number(f, 2) == 0 else { throw ContinuityError.message("The Samsung peer rejected authentication.") }
        let address = ProtoWire.bytes(f, 3)
        guard let peer = try profile.peers.first(where: { try ContinuityProfile.addressBytes($0.address) == address }) else { throw ContinuityError.message("The authenticated peer is absent from the imported account device list.") }
        let proof = Data(SHA256.hash(data: privateKey.publicKey.derRepresentation).prefix(6))
        guard proof == ProtoWire.bytes(f, 5) else { throw ContinuityError.message("The peer's authentication proof does not match this session.") }
        let remotePublic = ProtoWire.bytes(f, 4)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(derRepresentation: remotePublic))
        if let preferred = profile.preferredPeerAddress, try ContinuityProfile.addressBytes(preferred) != address { throw ContinuityError.message("A different Samsung device answered. Select the intended device and reconnect.") }
        sessionKey = shared.withUnsafeBytes { Data($0) }; authenticatedPeer = peer.name; authenticatedAddress = peer.address
        return try packet(ProtoWire.number(1, 3) + ProtoWire.bytes(5, Data(SHA256.hash(data: remotePublic).prefix(6))) + ProtoWire.number(8, profile.revision))
    }
}
