import Foundation
import Security
import CryptoKit

public enum ProfileStore {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.galaxy-continuity-lab.profile", kSecAttrAccount as String: "samsung-continuity"]
    public static func save(_ profile: ContinuityProfile) throws {
        try profile.validate(); let data = try JSONEncoder().encode(profile)
        if !ContinuityLoginStorage.usesKeychain { try CredentialFiles.save(data, name: "connection.json"); return }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw ContinuityError.message("Could not store the profile in Keychain.") }
        } else if status != errSecSuccess { throw ContinuityError.message("Keychain update failed (\(status)).") }
    }
    public static func load() throws -> ContinuityProfile {
        if !ContinuityLoginStorage.usesKeychain {
            guard let data = try CredentialFiles.load("connection.json") else { throw ContinuityError.message("Sign in with Samsung or import the existing Keychain login once.") }
            let profile = try JSONDecoder().decode(ContinuityProfile.self, from: data); try profile.validate(); return profile
        }
        guard let profile = try loadKeychainIfPresent() else { throw ContinuityError.message("Sign in with Samsung first.") }; return profile
    }
    static func loadKeychainIfPresent() throws -> ContinuityProfile? {
        var read = query; read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ContinuityError.message("Could not read the Continuity Keychain connection (\(status)).") }
        let profile = try JSONDecoder().decode(ContinuityProfile.self, from: data); try profile.validate(); return profile
    }
    public static func decrypt(_ envelope: Data, code: String) throws -> ContinuityProfile {
        struct Envelope: Decodable { var format: String; var version: Int; var sealed: Data }
        let value = try JSONDecoder().decode(Envelope.self, from: envelope)
        guard value.format == "galaxy-continuity-connection", value.version == 1, let key = Data(base64Encoded: code), key.count == 32 else { throw ContinuityError.message("Unsupported connection file or unlock code.") }
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: value.sealed), using: SymmetricKey(data: key))
        let profile = try JSONDecoder().decode(ContinuityProfile.self, from: data); try profile.validate(); return profile
    }
    public static func delete() throws {
        if !ContinuityLoginStorage.usesKeychain { try CredentialFiles.delete("connection.json"); return }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ContinuityError.message("Could not remove the Continuity connection (\(status)).") }
    }
}
