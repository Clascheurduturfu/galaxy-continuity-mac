import Foundation
import Network
import Darwin

public enum SMBStorageRecovery {
    public static func restore() throws { try SMBCompatibility.recover() }
}

/// A host-scoped, temporary preference for Samsung's SMB server. The original
/// user preferences are restored immediately after NetFS opens the session.
/// A private journal permits cleanup after an interrupted mount or app crash.
struct SMBCompatibility {
    struct Journal: Codable {
        let original: Data?
        let written: Data
        let block: Data
        let mode: UInt16
    }
    static let journalName = "smb-compatibility-lease.json"
    static var preferences: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/nsmb.conf") }
    let path: URL
    let journalDirectory: URL

    private static func read(_ path: URL) throws -> (Data, UInt16)? {
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw ContinuityError.message("Cannot safely access existing SMB preferences.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_size <= 262144 else {
            throw ContinuityError.message("Existing SMB preferences cannot be changed safely.")
        }
        return (try handle.readToEnd() ?? Data(), UInt16(info.st_mode & 0o777))
    }
    private static func write(_ data: Data, path: URL, mode: UInt16) throws {
        let temporary = path.deletingLastPathComponent().appendingPathComponent(".galaxy-smb-" + UUID().uuidString + ".tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(mode))
        guard fd >= 0 else { throw ContinuityError.message("Could not prepare the phone's SMB compatibility setting.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); _ = unlink(temporary.path) }
        try handle.write(contentsOf: data)
        guard fsync(fd) == 0, fchmod(fd, mode_t(mode)) == 0, rename(temporary.path, path.path) == 0 else {
            throw ContinuityError.message("Could not save the phone's SMB compatibility setting.")
        }
    }
    static func recover(path: URL = preferences, journalDirectory: URL = CredentialFiles.directory) throws {
        guard let data = try CredentialFiles.load(journalName, directory: journalDirectory) else { return }
        let journal = try JSONDecoder().decode(Journal.self, from: data)
        guard !journal.block.isEmpty, journal.block.count < 1024, journal.written.count <= 262144 else {
            throw ContinuityError.message("Invalid SMB compatibility recovery information.")
        }
        if let (current, _) = try read(path) {
            if current == journal.written {
                if let original = journal.original { try write(original, path: path, mode: journal.mode) }
                else if unlink(path.path) != 0 { throw ContinuityError.message("Could not remove the temporary SMB preference.") }
            } else if let range = current.range(of: journal.block) {
                // Preserve edits made by the user or another app during mounting.
                var preserved = current; preserved.removeSubrange(range)
                try write(preserved, path: path, mode: journal.mode)
            }
        }
        try CredentialFiles.delete(journalName, directory: journalDirectory)
    }
    init(host: String, path: URL = Self.preferences, journalDirectory: URL = CredentialFiles.directory) throws {
        guard IPv4Address(host) != nil else { throw ContinuityError.message("Invalid phone storage address.") }
        try Self.recover(path: path, journalDirectory: journalDirectory)
        let original = try Self.read(path)
        if let data = original?.0 {
            guard let text = String(data: data, encoding: .utf8) else { throw ContinuityError.message("Existing SMB preferences use an unsupported encoding.") }
            let sections = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            guard !sections.contains("[" + host + "]") else { throw ContinuityError.message("This phone already has custom SMB settings. They were left unchanged.") }
        }
        let id = UUID().uuidString
        let block = Data("\n# BEGIN Galaxy Continuity Lab \(id)\n[\(host)]\nprotocol_vers_map=2\n# END Galaxy Continuity Lab \(id)\n".utf8)
        let written = (original?.0 ?? Data()) + block
        let journal = Journal(original: original?.0, written: written, block: block, mode: original?.1 ?? 0o600)
        try CredentialFiles.save(JSONEncoder().encode(journal), name: Self.journalName, directory: journalDirectory)
        do { try Self.write(written, path: path, mode: journal.mode) }
        catch { try? Self.recover(path: path, journalDirectory: journalDirectory); throw error }
        self.path = path; self.journalDirectory = journalDirectory
    }
    func restore() throws { try Self.recover(path: path, journalDirectory: journalDirectory) }
}
