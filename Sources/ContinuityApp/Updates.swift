import SwiftUI
import AppKit
import CryptoKit
import ContinuityCore

private final class UpdateNetworkDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, GitHubUpdateRedirect.allowed(url) else { completionHandler(nil); return }
        var request = request
        if !GitHubUpdateRedirect.mayKeepAuthorization(url) { request.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if max(totalBytesWritten, totalBytesExpectedToWrite) > 128 * 1024 * 1024 { downloadTask.cancel() }
    }
}

@MainActor final class AppUpdates: ObservableObject {
    static let shared = AppUpdates()
    @Published var channel = UpdateChannel(rawValue: UserDefaults.standard.string(forKey: "updates.channel") ?? "preview") ?? .preview {
        didSet { UserDefaults.standard.set(channel.rawValue, forKey: "updates.channel"); release = nil; status = "Check the \(channel.branch) release channel." }
    }
    @Published var automaticallyCheck = UserDefaults.standard.bool(forKey: "updates.autoCheck") {
        didSet { UserDefaults.standard.set(automaticallyCheck, forKey: "updates.autoCheck") }
    }
    @Published var status = "Not checked yet."
    @Published var busy = false
    @Published var release: GitHubRelease?
    @Published var publicRepository: Bool?
    @Published var token = ""
    @Published var tokenSaved = !AppVersion.isRenderingDemo && (try? GitHubUpdateCredentials.load()) != nil
    private var launchChecked = false
    private let delegate = UpdateNetworkDelegate()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()
    var tokenCreationURL: URL { URL(string: "https://github.com/settings/personal-access-tokens/new?name=Galaxy-Continuity-Updater&target_name=Clascheurduturfu&expires_in=30&contents=read")! }
    var browserURL: URL { URL(string: "https://github.com/\(GitHubRelease.repository)/releases")! }
    var branchURL: URL { URL(string: "https://github.com/\(GitHubRelease.repository)/tree/\(channel.branch)")! }
    func saveToken() {
        do { try GitHubUpdateCredentials.save(token); tokenSaved = !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty; token = ""; status = tokenSaved ? "GitHub read access saved in a private local file." : "GitHub read access removed." }
        catch { status = "Could not save GitHub access. Use a read-only repository token." }
    }
    func checkAtLaunchIfEnabled() {
        guard !launchChecked else { return }; launchChecked = true
        // A saved private-repo token also triggers one anonymous probe per launch,
        // so making the repo public removes the token without another user action.
        if tokenSaved || (automaticallyCheck && Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: "updates.lastCheck") > 86_400) {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "updates.lastCheck"); check()
        }
    }
    private func request(_ url: URL, binary: Bool = false, authenticated: Bool = true) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(binary ? "application/octet-stream" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Galaxy-Continuity/\(AppVersion.short)", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if authenticated, let token = try GitHubUpdateCredentials.load() { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        return request
    }
    func check() {
        guard !busy else { return }; busy = true; release = nil
        let channel = channel
        Task {
            defer { busy = false }
            do {
                let url = URL(string: "https://api.github.com/repos/\(GitHubRelease.repository)/releases?per_page=100")!
                var (data, response) = try await session.data(for: request(url, authenticated: false))
                let anonymousStatus = (response as? HTTPURLResponse)?.statusCode
                if anonymousStatus == 404 || anonymousStatus == 401 {
                    publicRepository = false
                    if tokenSaved { (data, response) = try await session.data(for: request(url)) }
                }
                guard self.channel == channel else { return }
                guard let response = response as? HTTPURLResponse else { throw ContinuityError.message("GitHub did not return an HTTP response.") }
                if response.statusCode == 404 || response.statusCode == 401 {
                    status = "This repository is private or GitHub access expired. Add a read-only token below, or open Releases in your signed-in browser."; return
                }
                guard response.statusCode == 200, data.count <= 4 * 1024 * 1024 else { throw ContinuityError.message("GitHub could not complete the update check (HTTP \(response.statusCode)).") }
                let values = try JSONDecoder().decode([GitHubRelease].self, from: data)
                if anonymousStatus == 200 {
                    try GitHubUpdateCredentials.save(""); tokenSaved = false; token = ""
                    publicRepository = true
                }
                release = GitHubRelease.newest(values, channel: channel, after: AppVersion.short)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "updates.lastCheck")
                status = release.map { "\($0.tag_name) is available from \(channel.branch)." } ?? "No newer \(channel.title.lowercased()) release on \(channel.branch)."
            } catch { status = "Update check failed. Check your network or GitHub read access, then retry." }
        }
    }
    func install() {
        guard !busy, CallingController.shared.callState == .idle, let release else { return }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        guard let asset = release.asset(architecture: architecture), let expected = asset.sha256 else {
            status = "This release has no compatible app ZIP with a GitHub SHA-256 digest."; return
        }
        busy = true; status = "Downloading and checking \(release.tag_name)…"
        Task {
            var staging: URL?
            var handedOff = false
            defer {
                busy = false
                if !handedOff, let staging { try? FileManager.default.removeItem(at: staging) }
            }
            do {
                let (download, response) = try await session.download(for: request(asset.url, binary: true))
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ContinuityError.message("The release download was not authorized.") }
                let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Galaxy Continuity Lab/Updates", isDirectory: true)
                let stage = base.appendingPathComponent(UUID().uuidString, isDirectory: true); staging = stage
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let archive = stage.appendingPathComponent("update.zip")
                try FileManager.default.moveItem(at: download, to: archive)
                let app = try await Task.detached(priority: .utility) {
                    try Self.validateArchive(archive, expected: expected, size: asset.size, tag: release.tag_name, stage: stage)
                }.value
                guard CallingController.shared.callState == .idle else { throw ContinuityError.message("Finish the call, then install the update.") }
                let target = Bundle.main.bundleURL
                guard target.pathExtension == "app", FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else { throw ContinuityError.message("Move the app to a writable Applications folder, or install the download manually.") }
                let script = stage.appendingPathComponent("install.sh")
                let quoted: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                let shell = """
                #!/bin/bash
                set -euo pipefail
                stage=\(quoted(stage.path))
                target=\(quoted(target.path))
                source=\(quoted(app.path))
                for attempt in $(seq 1 60); do
                  kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null || break
                  sleep 0.5
                done
                kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null && exit 1
                next="$target.next-\(UUID().uuidString)"
                ditto "$source" "$next"
                codesign --verify --strict "$next"
                mv "$target" "$stage/previous.app"
                if ! mv "$next" "$target"; then mv "$stage/previous.app" "$target"; open -a "$target"; exit 1; fi
                if ! open -a "$target"; then rm -rf "$target"; mv "$stage/previous.app" "$target"; open -a "$target"; exit 1; fi
                rm -rf "$stage"
                """
                try shell.write(to: script, atomically: true, encoding: .utf8)
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash"); process.arguments = [script.path]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); handedOff = true
                NSApplication.shared.terminate(nil)
            } catch { status = error.localizedDescription }
        }
    }
    nonisolated private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0, data.count <= 4 * 1024 * 1024 else { throw ContinuityError.message("The update package could not be verified.") }
        return String(decoding: data, as: UTF8.self)
    }
    nonisolated private static func validateArchive(_ archive: URL, expected: String, size: Int, tag: String, stage: URL) throws -> URL {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard data.count == size, data.count <= 128 * 1024 * 1024,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected else { throw ContinuityError.message("The download failed its SHA-256 integrity check.") }
        let names = try run("/usr/bin/zipinfo", ["-1", archive.path]).split(separator: "\n")
        let root = "Galaxy Continuity Lab.app"
        guard !names.isEmpty, names.count <= 10_000, names.allSatisfy({ name in
            !name.hasPrefix("/") && !name.split(separator: "/").contains("..") && (name == Substring(root) || name.hasPrefix(root + "/") || name.hasPrefix("__MACOSX/"))
        }) else { throw ContinuityError.message("The update ZIP contains unexpected paths.") }
        let details = try run("/usr/bin/zipinfo", ["-l", archive.path])
        guard !details.split(separator: "\n").contains(where: { $0.hasPrefix("l") }) else { throw ContinuityError.message("The update ZIP contains unsupported symbolic links.") }
        let sizePattern = try NSRegularExpression(pattern: "([0-9]+) bytes uncompressed")
        guard let match = sizePattern.firstMatch(in: details, range: NSRange(details.startIndex..., in: details)),
              let range = Range(match.range(at: 1), in: details), let expanded = UInt64(details[range]), expanded <= 512 * 1024 * 1024 else {
            throw ContinuityError.message("The update ZIP expands beyond the allowed size.")
        }
        _ = try run("/usr/bin/ditto", ["-x", "-k", archive.path, stage.path])
        let app = stage.appendingPathComponent(root)
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        guard plist?["CFBundleIdentifier"] as? String == "local.galaxy-continuity-lab",
              let version = plist?["CFBundleShortVersionString"] as? String, ReleaseVersion(version) == ReleaseVersion(tag) else { throw ContinuityError.message("The update's app identity or version does not match the release.") }
        _ = try run("/usr/bin/codesign", ["--verify", "--strict", app.path])
        return app
    }
}

struct UpdatesCard: View {
    @ObservedObject private var updates = AppUpdates.shared
    var canInstall = true
    var body: some View {
        OneUICard {
            VStack(alignment: .leading, spacing: 12) {
                Label("App Updates", systemImage: "arrow.down.circle").font(.headline)
                Picker("Release channel", selection: $updates.channel) {
                    ForEach(UpdateChannel.allCases, id: \.self) { Text("\($0.title) · \($0.branch)").tag($0) }
                }.pickerStyle(.segmented).disabled(updates.busy)
                Text(updates.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Check for Updates") { updates.check() }.disabled(updates.busy).buttonStyle(OneUISecondaryButtonStyle()).help("Check published GitHub releases targeting the selected branch. Unreleased commits are not app updates.")
                    if updates.release != nil {
                        Button("Install & Restart") { updates.install() }.disabled(updates.busy || !canInstall || CallingController.shared.callState != .idle).buttonStyle(OneUIPrimaryButtonStyle())
                    }
                    Button("Releases") { NSWorkspace.shared.open(updates.browserURL) }.buttonStyle(OneUISecondaryButtonStyle()).help("Open published release downloads and release notes on GitHub.")
                    if updates.busy { ProgressView().controlSize(.small) }
                }
                Toggle("Check at launch, at most once a day", isOn: $updates.automaticallyCheck).toggleStyle(OneUIAlignedSwitchStyle())
                if updates.publicRepository != true {
                DisclosureGroup("Temporary private repository access") {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Temporary while the repository is private. Create a token with Contents: Read for only galaxy-continuity-mac. It is saved privately on this Mac and automatically deleted when an anonymous update check succeeds after publication.").font(.caption).foregroundStyle(.secondary)
                        SecureField(updates.tokenSaved ? "Read access saved · enter a replacement" : "GitHub read-only token", text: $updates.token).textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Create Read Token…") { NSWorkspace.shared.open(updates.tokenCreationURL) }
                                .help("Open GitHub's prefilled token form. Choose Only select repositories and galaxy-continuity-mac, then generate a token and paste it here.")
                            Button("Save Access") { updates.saveToken() }.disabled(updates.token.isEmpty)
                                .help("Save this read-only token in the Mac's owner-only app credential file; it is not added to source or releases.")
                            if updates.tokenSaved { Button("Remove Access") { updates.token = ""; updates.saveToken() }.help("Delete the local updater token. This does not revoke it in your GitHub account.") }
                            Button("Open \(updates.channel.branch) Branch") { NSWorkspace.shared.open(updates.branchURL) }.help("View the source branch used by the selected release channel.")
                        }
                    }.padding(.top, 8)
                }
                } else {
                    Text("Public repository · no access token needed. Any saved updater token has been removed from this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
