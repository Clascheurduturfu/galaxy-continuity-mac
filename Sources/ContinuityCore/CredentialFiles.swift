import Foundation
import Darwin

/// Development storage: account-level protection, without login-Keychain prompts.
/// These files contain secrets and must never be included in diagnostics/exports.
enum CredentialFiles {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Galaxy Continuity Lab/Credentials", isDirectory: true)
    }
    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), chmod(directory.path, 0o700) == 0 else {
            throw ContinuityError.message("The private login folder is not owned by this Mac user.")
        }
    }
    static func load(_ name: String, directory: URL = directory) throws -> Data? {
        try prepare(directory)
        let fd = open(directory.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw ContinuityError.message("Could not open the saved Continuity login.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size <= 1_048_576 else {
            throw ContinuityError.message("The saved Continuity login has unsafe permissions or an invalid format.")
        }
        return try handle.read(upToCount: 1_048_577)
    }
    static func save(_ data: Data, name: String, directory: URL = directory) throws {
        guard data.count <= 1_048_576 else { throw ContinuityError.message("Saved Continuity login is too large.") }
        try prepare(directory)
        let temporary = directory.appendingPathComponent("." + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ContinuityError.message("Could not create a private login file.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary.path, directory.appendingPathComponent(name).path) == 0 else {
            throw ContinuityError.message("Could not replace the saved Continuity login.")
        }
    }
    static func delete(_ name: String, directory: URL = directory) throws {
        try prepare(directory)
        guard unlink(directory.appendingPathComponent(name).path) == 0 || errno == ENOENT else {
            throw ContinuityError.message("Could not remove the saved Continuity login.")
        }
    }
}

public enum ContinuityLoginStorage {
    // This research build defaults to files at the owner's explicit request.
    public static var usesKeychain: Bool { UserDefaults.standard.bool(forKey: "continuity-use-keychain") }
    public static var description: String { usesKeychain ? "Mac Keychain" : "private files on this Mac (testing)" }
    /// Explicit, one-time import. Keychain may ask for access to each existing item.
    /// Leave the originals untouched so the previous build remains recoverable.
    public static func importKeychainForTesting() throws {
        if let credentials = try NativeAuthStore.loadKeychain() {
            try CredentialFiles.save(JSONEncoder().encode(credentials), name: "samsung-auth.json")
        }
        if let profile = try ProfileStore.loadKeychainIfPresent() {
            try CredentialFiles.save(JSONEncoder().encode(profile), name: "connection.json")
        }
        UserDefaults.standard.set(false, forKey: "continuity-use-keychain")
    }
}
