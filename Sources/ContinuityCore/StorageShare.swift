import Foundation
import NetFS
import Darwin

struct StorageCredentials: Decodable {
    struct Login: Decodable { let user: String; let password: String }
    let permissionStatus: String
    let resource: String?
    let ip: String?
    let credentials: Login?
}

/// Uses the phone's existing Storage Share consent and temporary SMB account.
@MainActor public final class StorageShare {
    private let session = FeatureSession(appID: 10)
    private var keepalive: Task<Void, Never>?
    private var generation = UUID()
    private var username: String?
    private var mounting = false
    private var requestedCredentials = false
    public private(set) var mountURL: URL?
    public var changed: (() -> Void)?
    public var status: ((String) -> Void)?
    public init() {
        session.status = { [weak self] in self?.status?($0) }
        session.received = { [weak self] data in
            Task { @MainActor in do { try await self?.handle(data) } catch { self?.status?(error.localizedDescription) } }
        }
    }
    public func connect(profile: ContinuityProfile, host: String? = nil, port: UInt16? = nil, sharing command: ClipboardSession? = nil) async throws {
        await disconnect(); generation = UUID(); requestedCredentials = false
        guard mountURL == nil else { throw ContinuityError.message("The previous phone drive is busy. Close its files before reconnecting.") }
        if let command { try await session.connect(profile: profile, sharing: command) }
        else if let host, let port { try await session.connect(profile: profile, host: host, port: port) }
        else { try await session.connect(profile: profile) }
        try await send("smbServerStatusReq")
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 10_000_000_000); try Task.checkCancellation(); try await self?.send("sessionKeepAliveReq") }
                catch { return }
            }
        }
    }
    private func send(_ value: String) async throws { try await session.send(Data(value.utf8)) }
    private func requestCredentials() async throws {
        guard !requestedCredentials else { return }; requestedCredentials = true
        try await send("smbGetCredentialsReq#Galaxy Continuity Lab for Mac")
        status?("Approve Storage Share on the phone when asked.")
    }
    private func handle(_ data: Data) async throws {
        guard data.count < 65536, let text = String(data: data, encoding: .utf8) else { throw ContinuityError.message("Invalid Storage Share message.") }
        let pieces = text.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(pieces[0]), body = pieces.count > 1 ? String(pieces[1]) : ""
        switch name {
        case "sessionKeepAliveReq": try await send("sessionKeepAliveResp")
        case "smbServerStatusReq": try await send("smbServerStatusResp#stopped")
        case "smbServerStatusResp":
            if body == "stopping" {
                status?("Waiting for the phone's previous storage session to stop…")
                let current = generation
                Task { try? await Task.sleep(nanoseconds: 2_000_000_000); guard current == self.generation else { return }; try? await self.send("smbServerStatusReq") }
            } else { try await requestCredentials() }
        case "smbGetCredentialsReq":
            // Reverse sharing is not enabled; never expose Mac files implicitly.
            try await send("smbGetCredentialsResp#" + #"{"permissionStatus":"permissionRejected"}"#)
        case "smbGetCredentialsResp":
            let value = try JSONDecoder().decode(StorageCredentials.self, from: Data(body.utf8))
            switch value.permissionStatus {
            case "permissionRequested": status?("Waiting for you to approve Storage Share on the phone…")
            case "permissionRejected": status?("Storage Share was declined on the phone.")
            case "permissionAllowed":
                // Phone versions can repeat the grant while NetFS is opening.
                // A duplicate is not malformed credentials and must not start a
                // second simultaneous mount of the same temporary account.
                guard !mounting, mountURL == nil else { return }
                guard let ip = value.ip, ip == session.peerIP,
                      let resource = value.resource, !resource.isEmpty, resource.count <= 255,
                      !resource.contains("/"), !resource.contains("\\"), resource != ".", resource != "..",
                      let credentials = value.credentials, !credentials.user.isEmpty, credentials.user.count <= 255,
                      credentials.password.count <= 1024 else { throw ContinuityError.message("The phone returned invalid storage connection details.") }
                mounting = true; defer { mounting = false }
                username = credentials.user
                let attempt = generation
                status?("Phone approved access. Mounting its storage in Finder…")
                let url: URL
                do {
                    url = try await Task.detached { try Self.mount(ip: ip, share: resource, user: credentials.user, password: credentials.password) }.value
                } catch {
                    if attempt == generation { try? await send("smbClientConnectionStatus#failed") }
                    throw error
                }
                guard attempt == generation else { _ = unmount(url.path, 0); return }
                mountURL = url; changed?()
                try await send("smbClientConnectionStatus#success")
                try await send("smbStorageCapacityReq")
                status?("Phone storage mounted. Open it in Finder.")
            default: throw ContinuityError.message("Unexpected Storage Share permission response.")
            }
        case "smbUnmountReq":
            if let url = mountURL {
                guard unmount(url.path, 0) == 0 else { try await send("smbUnmountResp#fail"); status?("Close files on the phone drive, then disconnect again."); return }
            }
            mountURL = nil; changed?(); try await send("smbUnmountResp#success")
        default: break
        }
    }
    private nonisolated static func mount(ip: String, share: String, user: String, password: String) throws -> URL {
        let compatibility = try SMBCompatibility(host: ip)
        defer { try? compatibility.restore() }
        var remote = URLComponents(); remote.scheme = "smb"; remote.host = ip; remote.path = "/" + share
        guard let url = remote.url else { throw ContinuityError.message("Invalid SMB share address.") }
        var points: Unmanaged<CFArray>?
        // Let NetAuth create a normal /Volumes mount. A custom mount under
        // Application Support is denied by macOS AppData privacy protection.
        let result = NetFSMountURLSync(url as CFURL, nil, user as CFString, password as CFString,
            CFDictionaryCreateMutableCopy(nil, 0, [kNAUIOptionKey: kNAUIOptionNoUI, kNetFSForceNewSessionKey: true] as CFDictionary),
            nil, &points)
        let mounts = points?.takeRetainedValue() as? [String]
        guard result == 0, let path = mounts?.first else {
            if result == ENOTCONN { throw ContinuityError.message("The phone closed the SMB connection during mounting (57). Disconnect storage and reconnect to request a fresh session.") }
            throw ContinuityError.message("macOS could not mount phone storage (\(result)).")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    public func disconnect() async {
        if let url = mountURL {
            guard unmount(url.path, 0) == 0 else { status?("Close files on the phone drive before disconnecting."); return }
            _ = rmdir(url.path); mountURL = nil; changed?()
        }
        generation = UUID(); keepalive?.cancel(); keepalive = nil
        if let username { try? await send("smbDeleteCredentialsReq#" + username) }
        self.username = nil; session.disconnect()
    }
}
