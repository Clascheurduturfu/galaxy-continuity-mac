import Foundation
import AppKit
import AuthenticationServices
import CommonCrypto
import CryptoKit
import Security
import IOBluetooth

// Browser bootstrap adapted from this owner's Samsung Cloud Notes implementation
// and Charles Bel's MIT-licensed samsung-re-health. See docs/THIRD_PARTY_NOTICES.md.
struct NativeCredentials: Codable {
    var authServer: String
    var masterToken: String
    var userID: String
    var loginID: String
    var deviceID: String
    var accessToken = ""
    var refreshToken = ""
    var accessExpires = Date.distantPast
    var registrationID = ""
    var cloudAuthorization = ""
    var cloudExpires = Date.distantPast
    var csr = ""
    var privateKeyData = Data()
    var bluetoothAddress = ""
}

enum ContinuityAuthCrypto {
    static func random(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw ContinuityError.message("Could not generate secure sign-in state.") }
        return data
    }
    static func url64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func challenge(_ value: String) -> String { url64(Data(SHA256.hash(data: Data(value.utf8)))) }
    static func aes(_ input: Data, key: Data, iv: Data? = nil, encrypt: Bool, ecb: Bool = false) throws -> Data {
        guard key.count == 16, iv == nil || iv?.count == 16 else { throw ContinuityError.message("Invalid Samsung encryption parameters.") }
        var output = Data(count: input.count + kCCBlockSizeAES128); let capacity = output.count
        var written = 0
        let status = output.withUnsafeMutableBytes { out in input.withUnsafeBytes { bytes in key.withUnsafeBytes { secret in
            func crypt(_ vector: UnsafeRawPointer?) -> CCCryptorStatus {
                CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding | (ecb ? kCCOptionECBMode : 0)), secret.baseAddress, key.count, vector, bytes.baseAddress, input.count, out.baseAddress, capacity, &written)
            }
            if let iv { return iv.withUnsafeBytes { crypt($0.baseAddress) } }
            return crypt(nil)
        } } }
        guard status == kCCSuccess else { throw ContinuityError.message("Samsung sign-in encryption could not be processed.") }
        return output.prefix(written)
    }
    static func callback(_ value: String, key: String) throws -> String {
        guard value.count <= 32_768, value.count % 2 == 0 else { throw ContinuityError.message("Invalid Samsung sign-in callback.") }
        var bytes = Data(); var at = value.startIndex
        while at < value.endIndex {
            let end = value.index(at, offsetBy: 2)
            guard let byte = UInt8(value[at..<end], radix: 16) else { throw ContinuityError.message("Invalid Samsung sign-in callback encoding.") }
            bytes.append(byte); at = end
        }
        var secret = Data(key.utf8.prefix(16)); secret.append(Data(repeating: 0, count: 16 - secret.count))
        guard let text = String(data: try aes(bytes, key: secret, encrypt: false, ecb: true), encoding: .utf8) else { throw ContinuityError.message("Samsung returned unreadable sign-in data.") }
        return text
    }
    static func envelope(_ payload: [String: Any], iterations: Int, publicKey: String) throws -> String {
        guard (1...1_000_000).contains(iterations), let der = Data(base64Encoded: publicKey) else { throw ContinuityError.message("Samsung returned invalid sign-in key material.") }
        let password = Data(SHA256.hash(data: Data(String(iterations).utf8))).base64EncodedString()
        let salt = try random(16); var key = Data(count: 16)
        let status = key.withUnsafeMutableBytes { output in salt.withUnsafeBytes { input in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, input.bindMemory(to: UInt8.self).baseAddress!, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), output.bindMemory(to: UInt8.self).baseAddress!, 16)
        } }
        guard status == kCCSuccess else { throw ContinuityError.message("Could not prepare Samsung sign-in encryption.") }
        // SecKey accepts PKCS#1. The entry point supplies an SPKI wrapper.
        func part(_ data: Data, _ position: inout Int) throws -> (UInt8, Data) {
            guard position + 2 <= data.count else { throw ContinuityError.message("Invalid Samsung public key.") }
            let tag = data[position]; position += 1; var length = Int(data[position]); position += 1
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard (1...4).contains(count), position + count <= data.count else { throw ContinuityError.message("Invalid Samsung public key length.") }
                length = 0
                for _ in 0..<count { length = length * 256 + Int(data[position]); position += 1 }
            }
            guard length <= data.count - position else { throw ContinuityError.message("Truncated Samsung public key.") }
            let value = data.subdata(in: position..<position + length); position += length
            return (tag, value)
        }
        var position = 0; let (_, sequence) = try part(der, &position); position = 0
        _ = try part(sequence, &position); let (tag, bits) = try part(sequence, &position)
        guard tag == 3, bits.first == 0 else { throw ContinuityError.message("Samsung returned an unsupported public key.") }
        var error: Unmanaged<CFError>?
        guard let rsa = SecKeyCreateWithData(Data(bits.dropFirst()) as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, &error),
              let encryptedKey = SecKeyCreateEncryptedData(rsa, .rsaEncryptionPKCS1, Data(key.base64EncodedString().utf8) as CFData, &error) as Data? else { throw ContinuityError.message("Could not encrypt the Samsung sign-in key.") }
        let iv = try random(16)
        let encrypted = try aes(JSONSerialization.data(withJSONObject: payload), key: key, iv: iv, encrypt: true)
        let envelope = ["chkDoNum": String(iterations), "svcEncParam": encrypted.base64EncodedString(), "svcEncKY": encryptedKey.base64EncodedString(), "svcEncIV": iv.map { String(format: "%02x", $0) }.joined()]
        return try JSONSerialization.data(withJSONObject: envelope).base64EncodedString()
    }
}

struct SamsungHTTPError: LocalizedError {
    let status: Int
    let path: String
    let code: Int64?
    let message: String
    var errorDescription: String? { message }
}

private final class AuthRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor public final class ContinuitySignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    public static let shared = ContinuitySignIn()
    static let masterClient = "yfrtglt53o"
    static let continuityClient = "boz0m1awhe"
    static let redirect = "ms-app://s-1-15-2-4027708247-2189610-1983755848-2937435718-1578786913-2158692839-1974417358"
    private var web: ASWebAuthenticationSession?
    private let transport = URLSession(configuration: .ephemeral, delegate: AuthRedirectGuard(), delegateQueue: nil)
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow() }
    func request(_ url: URL, form: [String: String]? = nil, json: [String: Any]? = nil, headers: [String: String] = [:], method: String? = nil) async throws -> [String: Any] {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host, host == "account.samsung.com" || host.hasSuffix(".samsungosp.com") || host == "api.samsungcloud.com" || host == "play.samsungcloud.com" || host.hasSuffix(".samsungmdec.com") else { throw ContinuityError.message("Samsung returned an untrusted sign-in destination.") }
        var request = URLRequest(url: url); request.timeoutInterval = 30
        request.httpMethod = method ?? (form == nil && json == nil ? "GET" : "POST")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let form {
            var parts = URLComponents(); parts.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = Data(parts.percentEncodedQuery!.replacingOccurrences(of: "+", with: "%2B").utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        if let json { request.httpBody = try JSONSerialization.data(withJSONObject: json); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        try Task.checkCancellation()
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.url == url else { throw ContinuityError.message("Samsung sign-in returned an unexpected destination.") }
        guard (200..<300).contains(response.statusCode) else {
            let failure = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = failure?["rcode"]
            let raw = failure?["error"] as? String ?? failure?["error_code"] as? String ?? ""
            let safeCode = !raw.isEmpty && raw.count <= 80 && raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }) ? ", " + raw : ""
            let safePath = url.path.replacingOccurrences(of: #"(?<=/users/)[^/]+|(?<=/lines/)[^/]+|(?<=/devices/)[^/]+"#, with: "<id>", options: .regularExpression)
            throw SamsungHTTPError(status: response.statusCode, path: url.path, code: (code as? NSNumber)?.int64Value, message: "Samsung request \(safePath) failed (HTTP \(response.statusCode)\(code.map { ", code \($0)" } ?? "")\(safeCode)).")
        }
        if data.isEmpty && [202, 204].contains(response.statusCode) { return [:] }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ContinuityError.message("Samsung returned an unsupported sign-in response.") }
        return result
    }
    private func browser(_ url: URL) async throws -> URL {
        guard web == nil else { throw ContinuityError.message("A Samsung sign-in is already open.") }
        return try await withCheckedThrowingContinuation { continuation in
            var completed = false
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "ms-app") { [weak self] callback, error in
                Task { @MainActor in
                    guard !completed else { return }; completed = true
                    self?.web = nil
                    if let callback { continuation.resume(returning: callback) }
                    else { continuation.resume(throwing: ContinuityError.message(error is ASWebAuthenticationSessionError ? "Samsung sign-in was cancelled." : "Samsung sign-in did not complete.")) }
                }
            }
            web = session; session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            if !session.start(), !completed { completed = true; web = nil; continuation.resume(throwing: ContinuityError.message("macOS could not open Samsung sign-in.")) }
        }
    }
    private func accountSignIn(status: (String) -> Void) async throws -> NativeCredentials {
        status("Preparing Samsung sign-in…")
        let entry = try await request(URL(string: "https://account.samsung.com/accounts/ANDROIDSDK/getEntryPoint")!)
        guard let signIn = entry["signInURI"] as? String, let uri = URL(string: signIn), uri.scheme == "https", uri.host == "account.samsung.com", uri.path.hasPrefix("/accounts/"), uri.query == nil, uri.fragment == nil,
              let key = entry["pkiPublicKey"] as? String, let rounds = Int(String(describing: entry["chkDoNum"] ?? "")) else { throw ContinuityError.message("Samsung returned incomplete sign-in configuration.") }
        let state = String(ContinuityAuthCrypto.url64(try ContinuityAuthCrypto.random(15)).prefix(20))
        let verifier = ContinuityAuthCrypto.url64(try ContinuityAuthCrypto.random(32))
        let previous = try NativeAuthStore.loadIfPresent()
        let device = previous?.deviceID ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        // The SDK entry point whitelists Android browser package identifiers even
        // on macOS. This compatibility value selects its standard web flow;
        // the actual browser, device name and OS remain those of this Mac.
        let payload: [String: Any] = ["clientId": Self.masterClient, "code_challenge": ContinuityAuthCrypto.challenge(verifier), "code_challenge_method": "S256", "competitorDeviceYNFlag": "Y", "countryCode": "fr", "deviceInfo": "Google|com.android.chrome", "deviceModelID": "Mac", "deviceName": "Galaxy Continuity Lab for Mac", "deviceOSVersion": ProcessInfo.processInfo.operatingSystemVersionString, "devicePhysicalAddressText": "MAC:" + device, "deviceType": "APP", "deviceUniqueID": device, "redirect_uri": Self.redirect, "replaceableClientConnectYN": "N", "replaceableClientId": "", "replaceableDevicePhysicalAddressText": "", "responseEncryptionType": "1", "responseEncryptionYNFlag": "Y", "scope": "", "state": state, "svcIptLgnID": "", "iosYNFlag": "Y"]
        var target = URLComponents(url: uri, resolvingAgainstBaseURL: false)!
        target.queryItems = [URLQueryItem(name: "locale", value: "en-US"), URLQueryItem(name: "svcParam", value: try ContinuityAuthCrypto.envelope(payload, iterations: rounds, publicKey: key)), URLQueryItem(name: "mode", value: "C")]
        let started = Date(); status("Complete sign-in in Samsung's secure browser window…")
        let callback = try await browser(target.url!)
        let expected = URL(string: Self.redirect)!
        guard callback.scheme == expected.scheme, callback.host == expected.host, callback.path == expected.path, callback.user == nil, callback.password == nil, Date().timeIntervalSince(started) < 900,
              let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false) else { throw ContinuityError.message("Samsung sign-in returned an invalid or expired callback.") }
        var items = parts.queryItems ?? []
        if let fragment = parts.fragment { var extra = URLComponents(); extra.percentEncodedQuery = fragment; items += extra.queryItems ?? [] }
        func field(_ name: String) throws -> String {
            let values = items.filter { $0.name == name }.compactMap(\.value)
            guard values.count == 1, !values[0].isEmpty else { throw ContinuityError.message("Samsung sign-in omitted \(name).") }
            return values[0]
        }
        let responseKey = try ContinuityAuthCrypto.callback(field("state"), key: state)
        let authority = try ContinuityAuthCrypto.callback(field("auth_server_url"), key: responseKey).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = authority.contains("://") ? authority : "https://" + authority
        let candidate = URL(string: normalized)
        guard let server = candidate, server.scheme?.lowercased() == "https", server.query == nil, server.fragment == nil, server.path.isEmpty || server.path == "/", server.user == nil, server.password == nil, server.port == nil || server.port == 443,
              let host = server.host?.lowercased(), host == "account.samsung.com" || host == "samsungosp.com" || host.hasSuffix(".samsungosp.com") else {
            let safeHost = candidate?.host ?? "invalid host"
            throw ContinuityError.message("Samsung returned an untrusted account server: \(safeHost), scheme \(candidate?.scheme ?? "none"), path \(candidate?.path ?? "none").")
        }
        let code = try ContinuityAuthCrypto.callback(field("code"), key: responseKey)
        let login = try ContinuityAuthCrypto.callback(field("retValue"), key: responseKey)
        status("Authorizing this Mac with Samsung…")
        let secureServer = URL(string: "https://" + host)!
        let result = try await request(secureServer.appendingPathComponent("auth/oauth2/authenticate"), form: ["grant_type": "authorization_code", "serviceType": "M", "client_id": Self.masterClient, "code": code, "code_verifier": verifier, "username": login, "physical_address_text": device])
        guard let token = (result["userauth_token"] ?? result["userAuthToken"]) as? String, let user = (result["userId"] ?? result["user_id"]) as? String, !token.isEmpty, !user.isEmpty else { throw ContinuityError.message("Samsung did not issue a reusable account connection.") }
        var credentials = NativeCredentials(authServer: "https://" + host, masterToken: token, userID: user, loginID: login, deviceID: device)
        if let previous, previous.userID == user { credentials = previous; credentials.authServer = "https://" + host; credentials.masterToken = token; credentials.loginID = login }
        try NativeAuthStore.save(credentials)
        return credentials
    }
    private func authorizeService(_ original: NativeCredentials) async throws -> NativeCredentials {
        var value = original
        let verifier = ContinuityAuthCrypto.url64(try ContinuityAuthCrypto.random(32))
        var target = URLComponents(string: value.authServer + "/auth/oauth2/v2/authorize")!
        target.queryItems = ["response_type": "code", "serviceType": "M", "client_id": Self.continuityClient, "scope": "offline.access", "code_challenge": ContinuityAuthCrypto.challenge(verifier), "code_challenge_method": "S256", "childAccountSupported": "Y", "userauth_token": value.masterToken, "physical_address_text": value.deviceID, "login_id": value.loginID].sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let authorization = try await request(target.url!)
        guard let code = authorization["code"] as? String, !code.isEmpty else { throw ContinuityError.message("Samsung did not authorize Galaxy Connect for this Mac.") }
        if let data = authorization["auth_data"] as? [String: Any], let user = data["userId"] as? String, user != value.userID { throw ContinuityError.message("Samsung returned a different account during Continuity authorization.") }
        let token = try await request(URL(string: value.authServer + "/auth/oauth2/token")!, form: ["grant_type": "authorization_code", "code": code, "client_id": Self.continuityClient, "client_secret": "", "physical_address_text": value.deviceID, "code_verifier": verifier])
        value = try updateToken(token, original: value)
        try NativeAuthStore.save(value); return value
    }
    private func updateToken(_ token: [String: Any], original: NativeCredentials) throws -> NativeCredentials {
        guard let access = token["access_token"] as? String, !access.isEmpty else { throw ContinuityError.message("Samsung did not issue a Continuity access token.") }
        var value = original; value.accessToken = access
        if let refresh = token["refresh_token"] as? String, !refresh.isEmpty { value.refreshToken = refresh }
        value.accessExpires = Date().addingTimeInterval((token["expires_in"] as? NSNumber)?.doubleValue ?? Double(token["expires_in"] as? String ?? "") ?? 3600)
        return value
    }
    private func serviceCredentials(_ original: NativeCredentials) async throws -> NativeCredentials {
        guard !original.accessToken.isEmpty else { return try await authorizeService(original) }
        guard original.accessExpires < Date().addingTimeInterval(120) else { return original }
        guard !original.refreshToken.isEmpty else { return try await authorizeService(original) }
        do {
            let token = try await request(URL(string: original.authServer + "/auth/oauth2/token")!, form: ["grant_type": "refresh_token", "refresh_token": original.refreshToken, "client_id": Self.continuityClient, "client_secret": "", "physical_address_text": original.deviceID])
            let value = try updateToken(token, original: original); try NativeAuthStore.save(value); return value
        } catch let error as SamsungHTTPError where [400, 401, 403].contains(error.status) { return try await authorizeService(original) }
    }
    private func identityHeaders(_ value: NativeCredentials) throws -> [String: String] {
        func identifier(_ text: String) throws -> String {
            let salt = Data("smcfcore".utf8); var output = Data(count: 16)
            let result = output.withUnsafeMutableBytes { out in salt.withUnsafeBytes { input in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), text, text.utf8.count, input.bindMemory(to: UInt8.self).baseAddress!, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 30, out.bindMemory(to: UInt8.self).baseAddress!, 16)
            } }
            guard result == kCCSuccess else { throw ContinuityError.message("Could not derive this installation's Continuity identifier.") }; return output.hexString
        }
        return ["x-sc-app-id": Self.continuityClient, "x-sc-app-version": "4.6.1217.0", "x-sc-uid": value.userID, "x-sc-access-token": value.accessToken, "x-sc-cdid": try identifier(value.deviceID + Self.continuityClient), "x-sc-pdid": try identifier(value.deviceID)]
    }
    private func cloudCredentials(_ original: NativeCredentials) async throws -> NativeCredentials {
        var value = try await serviceCredentials(original)
        if value.registrationID.isEmpty {
            let result = try await request(URL(string: "https://play.samsungcloud.com/identity/v2/user/register")!, json: ["app": ["version": "4.6.1217.0", "sdkVersion": "26100.0"], "device": ["osType": "win", "osVersion": "11", "platformVersion": "10.0.26100.0", "type": "pc", "countryCode": "FRA", "modelName": "Mac", "modelCode": "Mac", "alias": "Galaxy Continuity Lab for Mac", "osUserId": "0"]], headers: try identityHeaders(value))
            guard let device = result["dvcId"] as? String, !device.isEmpty,
                  let tokens = result["tokens"] as? [[String: Any]], let token = tokens.first(where: { $0["type"] as? String == "user" }),
                  let access = token["accessToken"] as? String, !access.isEmpty else { throw ContinuityError.message("Samsung did not return the Continuity installation registration.") }
            value.registrationID = device; value.cloudAuthorization = access; value.cloudExpires = Self.expiry(token)
            try NativeAuthStore.save(value)
        } else if value.cloudExpires < Date().addingTimeInterval(120) {
            var headers = try identityHeaders(value); headers.removeValue(forKey: "x-sc-cdid"); headers.removeValue(forKey: "x-sc-pdid"); headers["x-sc-dvc-id"] = value.registrationID
            let token = try await request(URL(string: "https://play.samsungcloud.com/identity/v2/user/token/renew")!, json: ["previousToken": value.cloudAuthorization], headers: headers)
            guard let access = token["accessToken"] as? String, !access.isEmpty else { throw ContinuityError.message("Samsung did not renew the Continuity cloud token.") }
            value.cloudAuthorization = access; value.cloudExpires = Self.expiry(token); try NativeAuthStore.save(value)
        }
        return value
    }
    private static func expiry(_ object: [String: Any]) -> Date {
        if let epoch = (object["expiresAt"] as? NSNumber)?.doubleValue ?? Double(object["expiresAt"] as? String ?? ""), epoch > 0 {
            return Date(timeIntervalSince1970: epoch > 100_000_000_000 ? epoch / 1000 : epoch)
        }
        return Date().addingTimeInterval((object["expiresIn"] as? NSNumber)?.doubleValue ?? 3600)
    }
    private func enroll(_ original: NativeCredentials, status: (String) -> Void) async throws -> ContinuityProfile {
        status("Authorizing Samsung Continuity for this Mac…")
        var value = try await cloudCredentials(original)
        guard let address = IOBluetoothHostController.default()?.addressAsString() else { throw ContinuityError.message("Enable Bluetooth so this Mac can register its own device identity.") }
        let bytes = try ContinuityProfile.addressBytes(address); let local = bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
        if !value.bluetoothAddress.isEmpty, value.bluetoothAddress != local { throw ContinuityError.message("This Mac's Bluetooth identity changed. Sign out and enroll it again.") }
        let url = URL(string: "https://play.samsungcloud.com/certificate/v2/certificates?kcid=KC01")!
        let headers = ["Authorization": "Bearer " + value.cloudAuthorization]
        status("Retrieving this Mac's Continuity certificate and device list…")
        do {
            let response = try await request(url, headers: headers)
            let bundle = try JSONDecoder().decode(ContinuityCertificateBundle.self, from: JSONSerialization.data(withJSONObject: response))
            if let device = bundle.thisDevice, (try? ContinuityProfile.addressBytes(device.btAddress ?? "")) == bytes {
                value.bluetoothAddress = local; try NativeAuthStore.save(value)
                return try bundle.profile(expectedAddress: local)
            }
        } catch let error as SamsungHTTPError {
            guard error.code == 40002001 else { throw error }
        }
        status("Enrolling a separate Mac Continuity identity…")
        if value.csr.isEmpty {
            let result = try ContinuityCSR.make(deviceID: value.registrationID)
            value.csr = result.request.base64EncodedString(); value.privateKeyData = result.privateKey
            try NativeAuthStore.save(value)
        }
        let response = try await request(url, json: ["csr": value.csr, "device": ["deviceName": "Galaxy Continuity Lab for Mac", "deviceModel": "Mac", "modelCode": "Mac", "deviceType": "pc", "btAddress": local, "wifiAddress": "", "irk": Data(repeating: 0, count: 16).base64EncodedString()]], headers: headers)
        let bundle = try JSONDecoder().decode(ContinuityCertificateBundle.self, from: JSONSerialization.data(withJSONObject: response))
        let profile = try bundle.profile(expectedAddress: local)
        value.bluetoothAddress = local; try NativeAuthStore.save(value); return profile
    }
    public func signIn(status: (String) -> Void) async throws -> ContinuityProfile { try await enroll(accountSignIn(status: status), status: status) }
    public func refresh(status: (String) -> Void, renewTokens: Bool = false) async throws -> ContinuityProfile {
        guard var value = try NativeAuthStore.loadIfPresent() else { throw ContinuityError.message("Sign in with Samsung first.") }
        if renewTokens { value.accessExpires = .distantPast; value.cloudExpires = .distantPast }
        return try await enroll(value, status: status)
    }
    public func signOut() throws { web?.cancel(); web = nil; try NativeAuthStore.delete(); try CredentialFiles.delete("samsung-calls.json") }
    public nonisolated func hasStoredSignIn() throws -> Bool { try NativeAuthStore.loadIfPresent() != nil }
    /// Account label for local UI only. Credentials and tokens never leave the store.
    public nonisolated func signedInAccountLabel() throws -> String? { try NativeAuthStore.loadIfPresent()?.loginID }
    /// Read-only CMC eligibility probe. Does not enroll a calling device or place a call.
    public func checkCallingAccount(status: (String) -> Void) async throws -> String {
        let context = try await callingContext(status: status)
        return "Samsung Phone authorization and account access succeeded (1 phone line, \(context.servers.count) signaling servers). Calling enrollment and audio are still to implement."
    }
    public func checkCallingTransport(status: (String) -> Void) async throws -> String {
        let context = try await callingContext(status: status)
        return try await CallingTransport.probe(servers: context.servers, status: status)
    }
    /// Temporary independent CMC enrollment and SIP registration, always removed
    /// afterward. Does not dial, answer, send SMS, or touch other device entries.
    public func testCallingRegistration(status: (String) -> Void) async throws -> String {
        let context = try await callingContext(status: status)
        guard !context.devices.contains(where: { $0["device_id"] as? String == context.deviceID }) else {
            throw ContinuityError.message("This Mac already has a calling enrollment; the temporary registration test will not replace it.")
        }
        let collection = context.entitlement.appendingPathComponent("1.0/users/\(context.userID)/lines/\(context.lineID)/devices")
        let ownURL = collection.appendingPathComponent(context.deviceID)
        status("Registering a separate temporary Mac calling identity…")
        let added = try await request(collection, json: context.enrollment, headers: context.headers)
        guard (added["response"] as? [String: Any])?["result"] as? Bool == true else {
            throw ContinuityError.message("Samsung did not accept the Mac calling enrollment.")
        }
        let cleanupData = try JSONSerialization.data(withJSONObject: ["device": context.deviceID, "url": ownURL.absoluteString])
        try CredentialFiles.save(cleanupData, name: "cmc-pending-cleanup.json")
        var probeResult: Result<String, Error>
        do {
            guard let server = context.servers.first else { throw ContinuityError.message("No Samsung calling server.") }
            let connection = try CallingSIPConnection(server: server)
            let timeout = Task { try? await Task.sleep(nanoseconds: 18_000_000_000); if !Task.isCancelled { connection.close() } }
            defer { timeout.cancel(); connection.close() }
            status("Mac calling identity accepted. Testing SIP registration…")
            try await connection.connect()
            let callID = UUID().uuidString, tag = String(UUID().uuidString.prefix(8)), contact = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
            let code = try await connection.register(context: context, callID: callID, fromTag: tag, cseq: 1, contact: contact, expires: 3600)
            if code == 200 {
                let endCode = try await connection.register(context: context, callID: callID, fromTag: tag, cseq: 2, contact: contact, expires: 0)
                guard endCode == 200 else { throw ContinuityError.message("SIP registered, but unregister returned \(endCode). Temporary enrollment will be removed.") }
                probeResult = .success("Independent Mac calling enrollment, SIP registration and unregister succeeded. No call was placed. The temporary enrollment was removed.")
            } else { probeResult = .failure(ContinuityError.message("Samsung accepted the Mac calling identity, but SIP registration returned \(code).")) }
        } catch { probeResult = .failure(error) }
        status("Removing only the temporary Mac calling enrollment…")
        var cleanupHeaders = context.headers; cleanupHeaders["Auth-Device-Id"] = context.deviceID
        do {
            let removed = try await request(ownURL, headers: cleanupHeaders, method: "DELETE")
            guard removed.isEmpty || (removed["response"] as? [String: Any])?["result"] as? Bool == true else {
                throw ContinuityError.message("Samsung has not confirmed removal.")
            }
            try CredentialFiles.delete("cmc-pending-cleanup.json")
        } catch {
            throw ContinuityError.message("The temporary Mac calling enrollment still needs removal. Its identifier is saved privately for recovery; other devices were untouched.")
        }
        return try probeResult.get()
    }
    func callingContext(status: (String) -> Void) async throws -> CallingAccountContext {
        struct CallingToken: Codable { var user: String; var device: String; var access: String; var refresh: String; var expires: Date }
        guard let account = try NativeAuthStore.loadIfPresent() else { throw ContinuityError.message("Sign in with Samsung first.") }
        let appID = "8f9l37bswj"
        var saved = try CredentialFiles.load("samsung-calls.json").flatMap { try? JSONDecoder().decode(CallingToken.self, from: $0) }
        if saved?.user != account.userID || saved?.device != account.deviceID || (saved?.expires ?? .distantPast) < Date().addingTimeInterval(120) {
            status("Requesting Samsung Phone authorization for this Mac…")
            let verifier = ContinuityAuthCrypto.url64(try ContinuityAuthCrypto.random(32))
            var target = URLComponents(string: account.authServer + "/auth/oauth2/v2/authorize")!
            // Phone's client rejects Galaxy Connect's offline.access scope;
            // request its registered default scopes and renew through account SSO.
            target.queryItems = ["response_type": "code", "serviceType": "M", "client_id": appID, "code_challenge": ContinuityAuthCrypto.challenge(verifier), "code_challenge_method": "S256", "childAccountSupported": "Y", "userauth_token": account.masterToken, "physical_address_text": account.deviceID, "login_id": account.loginID].sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            let authorization = try await request(target.url!)
            guard let code = authorization["code"] as? String, !code.isEmpty else { throw ContinuityError.message("Samsung Phone needs additional authorization; no calling device has been registered.") }
            let token = try await request(URL(string: account.authServer + "/auth/oauth2/token")!, form: ["grant_type": "authorization_code", "code": code, "client_id": appID, "client_secret": "", "physical_address_text": account.deviceID, "code_verifier": verifier])
            guard let access = token["access_token"] as? String, !access.isEmpty else { throw ContinuityError.message("Samsung did not issue Phone authorization.") }
            let seconds = (token["expires_in"] as? NSNumber)?.doubleValue ?? Double(token["expires_in"] as? String ?? "") ?? 3600
            saved = CallingToken(user: account.userID, device: account.deviceID, access: access, refresh: token["refresh_token"] as? String ?? "", expires: Date().addingTimeInterval(seconds))
            try CredentialFiles.save(JSONEncoder().encode(saved!), name: "samsung-calls.json")
        }
        guard let saved, let user = account.userID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { throw ContinuityError.message("Invalid calling account.") }
        let headers = ["Access-Token": saved.access, "Auth-Server-Url": URL(string: account.authServer)!.host!, "Auth-Device-Id": account.deviceID, "x-osp-clientosversion": "macOS", "x-osp-clientmodel": "Mac", "x-osp-appId": appID, "x-osp-packagename": "com.samsung.android.mdecservice", "x-osp-packageversion": "1.0.0"]
        status("Samsung Phone authorized. Checking its account service…")
        let local = try await request(URL(string: "https://acs.samsungmdec.com/1.0/users/\(user)/localacsaddress")!, headers: headers)
        guard let name = local["local_acs_address"] as? String, !name.contains("/"), let server = URL(string: "https://" + name) else { throw ContinuityError.message("Samsung returned an invalid calling service address.") }
        let entitlement = try await request(server.appendingPathComponent("1.0/defaultentitlementserveraddress"), headers: headers)
        guard let address = entitlement["entitlement_server_address"] as? String, let es = URL(string: address) else { throw ContinuityError.message("Samsung returned no calling account service.") }
        let info = try await request(es.appendingPathComponent("1.0/users/\(user)"), headers: headers)
        let lines = info["line"] as? [[String: Any]] ?? []
        guard lines.count == 1, let line = lines.first, let id = line["line_id"] as? String, !id.contains("/"), !id.isEmpty else {
            throw ContinuityError.message("Calling setup needs exactly one selected phone line.")
        }
            var configHeaders = headers
            let devices = line["device"] as? [[String: Any]] ?? []
            guard let primary = devices.first(where: { $0["device_type"] as? String == "Phone" }), let identifier = primary["device_id"] as? String else {
                throw ContinuityError.message("Samsung returned no primary calling phone.")
            }
            configHeaders["Auth-Device-Id"] = identifier
            let response = try await request(server.appendingPathComponent("1.0/users/\(user)/lines/\(id)/deviceconfiguration"), headers: configHeaders)
            let config = response["configurations"] as? [String: Any] ?? [:]
            let servers = config["pcscf_address_list"] as? [String] ?? []
            return CallingAccountContext(userID: account.userID, installationID: account.deviceID, lineID: id,
                                         primaryID: identifier, servers: servers, headers: headers, entitlement: es, devices: devices)
    }
}

enum NativeAuthStore {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.galaxy-continuity-lab.native-auth", kSecAttrAccount as String: "continuity-native"] }
    static func loadIfPresent() throws -> NativeCredentials? {
        if !ContinuityLoginStorage.usesKeychain {
            guard let data = try CredentialFiles.load("samsung-auth.json") else { return nil }
            return try JSONDecoder().decode(NativeCredentials.self, from: data)
        }
        return try loadKeychain()
    }
    static func loadKeychain() throws -> NativeCredentials? {
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ContinuityError.message("Unlock the Mac Keychain to access Samsung sign-in (\(status)).") }
        return try JSONDecoder().decode(NativeCredentials.self, from: data)
    }
    static func save(_ value: NativeCredentials) throws {
        let data = try JSONEncoder().encode(value); guard data.count <= 65536 else { throw ContinuityError.message("Samsung sign-in state exceeds its storage limit.") }
        if !ContinuityLoginStorage.usesKeychain { try CredentialFiles.save(data, name: "samsung-auth.json"); return }
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ContinuityError.message("Could not save Samsung sign-in in Keychain (\(status)).") }
    }
    static func delete() throws {
        if !ContinuityLoginStorage.usesKeychain { try CredentialFiles.delete("samsung-auth.json"); return }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ContinuityError.message("Could not remove Samsung sign-in from Keychain (\(status)).") }
    }
}
