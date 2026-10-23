import Foundation

public enum UpdateChannel: String, CaseIterable, Codable, Sendable {
    case stable, preview
    public var branch: String { self == .stable ? "main" : "preview" }
    public var title: String { rawValue.capitalized }
}

public struct ReleaseVersion: Comparable, Equatable, Sendable {
    let numbers: [Int]
    let stage: Int
    let iteration: Int
    public init?(_ text: String) {
        let text = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let halves = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let base = halves.first else { return nil }
        let parts = base.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ Int($0) != nil }) else { return nil }
        numbers = parts.map { Int($0)! } + Array(repeating: 0, count: 3 - parts.count)
        if halves.count == 1 { stage = 4; iteration = 0 }
        else {
            let suffix = halves[1].split(separator: ".")
            guard suffix.count == 2, let order = ["alpha": 0, "preview": 1, "beta": 2, "rc": 3][String(suffix[0])], let value = Int(suffix[1]), value >= 0 else { return nil }
            stage = order; iteration = value
        }
    }
    public static func < (a: Self, b: Self) -> Bool {
        if a.numbers != b.numbers { return a.numbers.lexicographicallyPrecedes(b.numbers) }
        return a.stage != b.stage ? a.stage < b.stage : a.iteration < b.iteration
    }
}

public struct GitHubRelease: Decodable, Sendable {
    public static let repository = "Clascheurduturfu/galaxy-continuity-mac"
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let url: URL
        public let size: Int
        public let digest: String?
        public var sha256: String? {
            guard let digest, digest.hasPrefix("sha256:") else { return nil }
            let hex = String(digest.dropFirst(7)).lowercased()
            return hex.count == 64 && hex.allSatisfy({ $0.isHexDigit && $0.isASCII }) ? hex : nil
        }
        public var trustedAPIURL: Bool {
            url.scheme == "https" && url.host == "api.github.com" && url.port == nil && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil &&
            url.path.hasPrefix("/repos/\(GitHubRelease.repository)/releases/assets/") && Int(url.lastPathComponent) != nil
        }
    }
    public let tag_name: String
    public let target_commitish: String
    public let html_url: URL
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]
    public func asset(architecture: String) -> Asset? {
        assets.first { $0.name.hasSuffix("-macOS-\(architecture).zip") && $0.size > 0 && $0.size <= 128 * 1024 * 1024 && $0.sha256 != nil && $0.trustedAPIURL }
    }
    public static func newest(_ releases: [GitHubRelease], channel: UpdateChannel, after installed: String) -> GitHubRelease? {
        guard let current = ReleaseVersion(installed) else { return nil }
        return releases.filter {
            !$0.draft && $0.target_commitish == channel.branch &&
            (channel == .preview || !$0.prerelease) &&
            $0.html_url.scheme == "https" && $0.html_url.host == "github.com" &&
            $0.html_url.path.hasPrefix("/\(repository)/releases/tag/") &&
            ReleaseVersion($0.tag_name).map { $0 > current } == true
        }.max { ReleaseVersion($0.tag_name)! < ReleaseVersion($1.tag_name)! }
    }
}

public enum GitHubUpdateCredentials {
    public static func load() throws -> String? {
        try CredentialFiles.load("github-updates.token").flatMap { String(data: $0, encoding: .utf8) }
    }
    public static func save(_ text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 512, text.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline }) else { throw ContinuityError.message("Invalid GitHub access token.") }
        if text.isEmpty { try CredentialFiles.delete("github-updates.token") }
        else { try CredentialFiles.save(Data(text.utf8), name: "github-updates.token") }
    }
}

/// Redirect allowlist shared by the updater and its security regression tests.
public enum GitHubUpdateRedirect {
    public static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host else { return false }
        return host == "api.github.com" || host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }
    public static func mayKeepAuthorization(_ url: URL) -> Bool { allowed(url) && url.host == "api.github.com" }
}
