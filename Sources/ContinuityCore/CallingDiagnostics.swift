import Foundation

/// Bounded call diagnostics: `~/Library/Caches/Galaxy Continuity Lab/call-diagnostics.log`, mode 0600, at most
/// ~256 KB (the oldest half is dropped when full). Contains dialog state transitions, SIP method/status words,
/// the media endpoint host:port and per-second media counters. Never keys, tokens, numbers, SDP or audio.
final class CallingDiagnostics: @unchecked Sendable {
    static let shared = CallingDiagnostics()
    static let limit = 256 * 1024
    private let queue = DispatchQueue(label: "calling.diagnostics")
    let url: URL
    private let formatter: DateFormatter

    init(directory: URL? = nil, name: String = "call-diagnostics.log") {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Galaxy Continuity Lab", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        url = base.appendingPathComponent(name)
        formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss.SSS"
    }

    func log(_ line: String) {
        let date = Date()
        queue.async { [self] in
            let stamp = formatter.string(from: date)
            let text = "\(stamp) \(line.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").prefix(1024))\n"
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            guard let handle = try? FileHandle(forUpdating: url) else { return }
            defer { try? handle.close() }
            chmod(url.path, 0o600)
            let size = (try? handle.seekToEnd()) ?? 0
            if size + UInt64(text.utf8.count) > UInt64(Self.limit) {
                try? handle.seek(toOffset: size / 2)
                let tail = (try? handle.readToEnd()) ?? Data()
                let cut = tail.firstIndex(of: 10).map { tail.index(after: $0) } ?? tail.startIndex
                try? handle.truncate(atOffset: 0); try? handle.seek(toOffset: 0)
                try? handle.write(contentsOf: tail[cut...])
            }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        }
    }

    /// Blocks until queued lines are on disk (tests, self-test exit).
    func flush() { queue.sync {} }
    func clear() { queue.sync { try? FileManager.default.removeItem(at: url) } }
}

extension CallingEndReason {
    var diagnosticLabel: String {
        switch self {
        case .failed(let code, _): return "failed status=\(code)"
        case .localHangup: return "localHangup"
        case .remoteHangup: return "remoteHangup"
        case .cancelledByCaller: return "cancelledByCaller"
        case .remoteCancelled: return "remoteCancelled"
        case .declined: return "declined"
        case .timeout: return "timeout"
        case .transportLost: return "transportLost"
        }
    }
}
