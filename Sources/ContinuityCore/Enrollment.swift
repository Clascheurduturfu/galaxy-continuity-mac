import Foundation
import Security

struct ContinuityCertificateBundle: Decodable {
    struct AccountKey: Decodable { var aes256Key: Data; var expireTime: Int64 }
    struct Device: Decodable { var btAddress: String?; var deviceName: String?; var deviceType: String?; var deviceModel: String?; var createTime: Int64? }
    var userFingerprint: String
    var userAesKeys: [AccountKey]
    var revision: UInt64
    var thisDevice: Device?
    var devices: [Device]
    func profile(expectedAddress: String, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> ContinuityProfile {
        guard let current = thisDevice?.btAddress,
              try ContinuityProfile.addressBytes(current) == ContinuityProfile.addressBytes(expectedAddress) else { throw ContinuityError.message("Samsung's certificate does not identify this Mac. The existing connection was preserved.") }
        guard userFingerprint.count == 64, userFingerprint.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let key = userAesKeys.filter({ $0.expireTime > now && $0.aes256Key.count == 32 }).min(by: { $0.expireTime < $1.expireTime }) else { throw ContinuityError.message("Samsung returned no usable Continuity account key or fingerprint.") }
        var fingerprint = Data(), cursor = userFingerprint.startIndex
        while cursor < userFingerprint.endIndex { let end = userFingerprint.index(cursor, offsetBy: 2); fingerprint.append(UInt8(userFingerprint[cursor..<end], radix: 16)!); cursor = end }
        var unique: [Data: ContinuityProfile.Peer] = [:]
        for device in devices.sorted(by: { ($0.createTime ?? 0) < ($1.createTime ?? 0) }) {
            guard let address = device.btAddress, let bytes = try? ContinuityProfile.addressBytes(address), bytes != (try ContinuityProfile.addressBytes(expectedAddress)) else { continue }
            unique[bytes] = ContinuityProfile.Peer(address: address, name: device.deviceName ?? "Samsung device", deviceType: device.deviceType, model: device.deviceModel)
        }
        let peers = unique.values.sorted { $0.address < $1.address }
        let value = ContinuityProfile(format: "galaxy-continuity-profile-v1", accountKey: key.aes256Key, localBluetoothAddress: expectedAddress, peers: peers, revision: revision, expiresAt: key.expireTime, borrowedIdentity: false, accountFingerprint: fingerprint, preferredPeerAddress: peers.first(where: { $0.deviceType == "phone" })?.address)
        try value.validate(); return value
    }
}

enum ContinuityCSR {
    static func der(_ tag: UInt8, _ value: Data) -> Data {
        var length = Data()
        if value.count < 128 { length.append(UInt8(value.count)) }
        else {
            var count = value.count, bytes = [UInt8]()
            while count > 0 { bytes.insert(UInt8(count & 255), at: 0); count >>= 8 }
            length.append(0x80 | UInt8(bytes.count)); length.append(contentsOf: bytes)
        }
        return Data([tag]) + length + value
    }
    static func make(deviceID: String) throws -> (request: Data, privateKey: Data) {
        guard !deviceID.isEmpty, deviceID.utf8.count < 256 else { throw ContinuityError.message("Invalid Continuity registration identifier.") }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(key), let publicData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
              let privateData = SecKeyCopyExternalRepresentation(key, &error) as Data? else { throw ContinuityError.message("Could not create this Mac's Continuity certificate request.") }
        let rsa = der(0x30, der(6, Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,1,1])) + der(5, Data()))
        let signing = der(0x30, der(6, Data([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,1,11])) + der(5, Data()))
        func attribute(_ oid: [UInt8], _ text: String, tag: UInt8 = 12) -> Data { der(0x31, der(0x30, der(6, Data(oid)) + der(tag, Data(text.utf8)))) }
        let name = der(0x30, attribute([0x55,4,3], deviceID) + attribute([0x55,4,10], "Samsung Electronics") + attribute([0x55,4,11], "CSP") + attribute([0x55,4,7], "") + attribute([0x55,4,8], "") + attribute([0x55,4,6], "KR", tag: 19) + attribute([0x2a,0x86,0x48,0x86,0xf7,0x0d,1,9,1], "", tag: 22))
        let info = der(0x30, der(2, Data([0])) + name + der(0x30, rsa + der(3, Data([0]) + publicData)) + der(0xa0, Data()))
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, info as CFData, &error) as Data? else { throw ContinuityError.message("Could not sign this Mac's Continuity certificate request.") }
        return (der(0x30, info + signing + der(3, Data([0]) + signature)), privateData)
    }
}
