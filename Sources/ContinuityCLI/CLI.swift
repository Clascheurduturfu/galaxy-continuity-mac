import Foundation
import Darwin
import AppKit
import ContinuityCore

@main struct ContinuityCLI {
    @MainActor static func main() {
        let args = CommandLine.arguments
        // Keep a source alive before scheduling asynchronous connection work.
        let keepAlive = Timer(timeInterval: 3600, repeats: true) { _ in }
        RunLoop.main.add(keepAlive, forMode: .common)
        let command = args.dropFirst().first ?? "help"
        do {
            if command == "version" { print("Galaxy Continuity v1.0"); return }
            if ["cmc-check", "cmc-transport", "cmc-register-test"].contains(command) {
                Task {
                    do {
                        let report: (String) -> Void = { print($0); fflush(stdout) }
                        let result: String
                        if command == "cmc-register-test" { result = try await ContinuitySignIn.shared.testCallingRegistration(status: report) }
                        else if command == "cmc-transport" { result = try await ContinuitySignIn.shared.checkCallingTransport(status: report) }
                        else { result = try await ContinuitySignIn.shared.checkCallingAccount(status: report) }
                        print(result); exit(0)
                    }
                    catch { print(error.localizedDescription); exit(1) }
                }
                RunLoop.main.run(); return
            }
            if ["cmc-register", "cmc-dial", "cmc-answer-next"].contains(command) {
                // cmc-register <seconds> [--reregister]   : registers, never answers anything, unregisters.
                // cmc-dial <number> <seconds> --place-real-call      : REAL outgoing call. Owner only.
                // cmc-answer-next <seconds> --answer-real-call       : REAL incoming call answer. Owner only.
                let flags = Set(args.filter { $0.hasPrefix("--") })
                let values = args.dropFirst(2).filter { !$0.hasPrefix("--") }
                if command == "cmc-dial", !flags.contains("--place-real-call") { print("Refusing: cmc-dial places a real call. Add --place-real-call to confirm."); exit(2) }
                if command == "cmc-answer-next", !flags.contains("--answer-real-call") { print("Refusing: cmc-answer-next answers a real call. Add --answer-real-call to confirm."); exit(2) }
                Task { @MainActor in
                    let calls = CallingController()
                    let say: (String) -> Void = { print($0); fflush(stdout) }
                    do {
                        calls.incomingPolicy = command == "cmc-answer-next" ? .interactive : .observeOnly
                        try await calls.startAndWait()
                        say("Registered. \(calls.status)")
                        say("REGISTER 200 shape: \(calls.registrationShape)")
                        if command == "cmc-register" {
                            let seconds = Int(values.first ?? "") ?? 60
                            for tick in 0..<seconds {
                                try await Task.sleep(nanoseconds: 1_000_000_000)
                                if flags.contains("--reregister"), tick == seconds / 2 {
                                    let expiry = try await calls.refreshRegistration()
                                    say("Re-REGISTER accepted (granted expiry \(expiry) s).")
                                }
                                if calls.phase != .registered { say("Phase changed: \(calls.status)") }
                            }
                        } else if command == "cmc-dial" {
                            guard values.count >= 1 else { print("Usage: cmc-dial <number> [seconds] --place-real-call"); exit(2) }
                            calls.dial(number: values[0])
                            let seconds = Int(values.dropFirst().first ?? "") ?? 20
                            var last = ""
                            for _ in 0..<(seconds * 2) {
                                try await Task.sleep(nanoseconds: 500_000_000)
                                if "\(calls.callState)" != last { last = "\(calls.callState)"; say("Call state: \(last) · \(calls.status)") }
                                if calls.callState == .idle, last != "" , last != "idle" { break }
                            }
                            calls.hangUp(); try await Task.sleep(nanoseconds: 2_000_000_000)
                        } else {
                            let seconds = Int(values.first ?? "") ?? 60
                            say("Waiting up to 120 s for an incoming call; it is answered automatically and ended after \(seconds) s.")
                            var answered = false
                            for _ in 0..<240 {
                                try await Task.sleep(nanoseconds: 500_000_000)
                                if calls.hasIncomingCall { calls.answer(); answered = true; say("Incoming call answered."); break }
                            }
                            if answered { try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000); calls.hangUp(); try await Task.sleep(nanoseconds: 2_000_000_000) }
                        }
                        await calls.stopAndWait()
                        say("Subscriptions: \(calls.subscriptionReport)")
                        say("Stopped. Unregister status \(calls.unregisterCode.map(String.init) ?? "n/a"); REGISTER 200s \(calls.registerCount); incoming INVITEs seen \(calls.incomingInviteCount); server request methods: \(calls.requestMethods.joined(separator: ",")).")
                        exit(0)
                    } catch {
                        say("Calling: \(error.localizedDescription)")
                        await calls.stopAndWait()
                        exit(1)
                    }
                }
                RunLoop.main.run(); return
            }
            if command == "feature-auto", args.count >= 3, let appID = UInt8(args[2]), [1, 10].contains(appID) {
                let profile = try ProfileStore.load(), feature = FeatureSession(appID: appID)
                feature.status = { print($0); fflush(stdout) }
                feature.received = { print("Feature received \($0.count) bytes"); fflush(stdout) }
                Task {
                    do { try await feature.connect(profile: profile); try await Task.sleep(nanoseconds: 8_000_000_000); feature.disconnect(); exit(0) }
                    catch { print("Feature: \(error.localizedDescription)"); feature.disconnect(); exit(1) }
                }
                RunLoop.main.run(); return
            }
            if command == "feature-probe", args.count >= 5, let port = UInt16(args[3]), let appID = UInt8(args[4]), [1, 10].contains(appID) {
                let profile = try ProfileStore.load()
                let feature = FeatureSession(appID: appID)
                feature.status = { print($0); fflush(stdout) }
                feature.received = { data in
                    // Storage credentials must not be printed, even in a probe.
                    let text = String(data: data, encoding: .utf8) ?? ""
                    print("Feature message: \(text.split(separator: "#", maxSplits: 1).first.map(String.init) ?? "binary") (\(data.count) bytes)"); fflush(stdout)
                    if text == "sessionKeepAliveReq" { Task { try? await feature.send(Data("sessionKeepAliveResp".utf8)) } }
                }
                Task {
                    do {
                        try await feature.connect(profile: profile, host: args[2], port: port)
                        if appID == 10 { try await feature.send(Data("smbServerStatusReq".utf8)) }
                        try await Task.sleep(nanoseconds: 12_000_000_000)
                        feature.disconnect(); exit(0)
                    } catch { print("Feature probe: \(error.localizedDescription)"); feature.disconnect(); exit(1) }
                }
                RunLoop.main.run(); return
            }
            if command == "ble-scan" {
                let discovery = BluetoothDiscovery()
                var states: [String] = []
                discovery.status = { states.append($0); print($0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    discovery.stop()
                    let result = states.joined(separator: "\n") + "\nNearby BLE devices: \(discovery.nearbyCount); Samsung advertisements: \(discovery.samsungCount); advertised Samsung hotspot services: \(discovery.hotspotPeers.count)\n"
                    print(result)
                    if let index = args.firstIndex(of: "--output"), index + 1 < args.count { try? result.write(toFile: args[index + 1], atomically: true, encoding: .utf8) }
                    if let index = args.firstIndex(of: "--capture"), index + 1 < args.count { try? JSONSerialization.data(withJSONObject: discovery.samsungFrames).write(to: URL(fileURLWithPath: args[index + 1]), options: .atomic) }
                    exit(0)
                }
                RunLoop.main.run(); return
            }
            let profile: ContinuityProfile?
            if args.contains("--profile-stdin") || args.contains("--profile-fifo") {
                let input: Data
                if let i = args.firstIndex(of: "--profile-fifo"), i + 1 < args.count {
                    let path = args[i + 1]
                    var info = stat()
                    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFIFO,
                          let handle = FileHandle(forReadingAtPath: path) else { throw ContinuityError.message("Profile input must be a named pipe.") }
                    defer { try? handle.close() }; input = handle.readDataToEndOfFile()
                } else { input = FileHandle.standardInput.readDataToEndOfFile() }
                profile = try JSONDecoder().decode(ContinuityProfile.self, from: input); try profile!.validate()
            } else { profile = nil }
            if command == "ble-probe" {
                let selected = try profile ?? ProfileStore.load()
                var lines: [String] = []
                func report(_ text: String) {
                    lines.append(text); print(text)
                    if let i = args.firstIndex(of: "--output"), i + 1 < args.count { try? (lines.joined(separator: "\n") + "\n").write(toFile: args[i + 1], atomically: true, encoding: .utf8) }
                }
                let transport = try BLEMCFTransport(profile: selected); transport.status = report
                _ = NSApplication.shared
                Task {
                    defer { transport.cancel() }
                    do { _ = try await transport.authenticate(profile: selected); report("SUCCESS: Direct Mac-to-Samsung BLE account authentication completed."); exit(0) }
                    catch { report("BLE probe failed: " + error.localizedDescription); exit(1) }
                }
                NSApplication.shared.run(); return
            }
            if command == "import-profile" {
                guard let profile else { throw ContinuityError.message("Use --profile-stdin to supply a profile securely.") }
                try ProfileStore.save(profile); print("Continuity profile stored in Keychain."); return
            }
            if command == "scan" {
                let discovery = ContinuityDiscovery(); discovery.profile = profile ?? (try? ProfileStore.load())
                discovery.failed = { fputs(($0 + "\n"), stderr) }
                discovery.start()
                let seconds = args.firstIndex(of: "--seconds").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 12
                DispatchQueue.main.asyncAfter(deadline: .now() + min(60, max(1, seconds))) {
                    let values = discovery.devices.map { ["name": $0.name, "host": $0.host, "port": String($0.port), "recognized": $0.address == nil ? "false" : "true", "instance": $0.instance] }
                    let data = try! JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
                    print(String(decoding: data, as: UTF8.self)); discovery.stop(); exit(0)
                }
                RunLoop.main.run(); return
            }
            if command == "ble-contexts", let i = args.firstIndex(of: "--peer"), i + 1 < args.count {
                // Decode the account-encrypted advertisement context of one registered device.
                let selected = try profile ?? ProfileStore.load()
                guard let fingerprint = selected.accountFingerprint else { throw ContinuityError.message("Profile lacks the account fingerprint.") }
                let discovery = BluetoothDiscovery()
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    discovery.stop()
                    var seen = Set<String>()
                    for frame in discovery.samsungFrames {
                        guard let bytes = frame["manufacturer"].flatMap({ Data(base64Encoded: $0) }),
                              let context = MCFAdvertisement.context(manufacturer: bytes, fingerprint: fingerprint, targetAddress: args[i + 1]) else { continue }
                        let raw = Array(context), start = Int(raw[14]), end = start + Int(raw[15]); var cursor = start, tags: [String] = []
                        func hex(_ bytes: ArraySlice<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
                        while cursor < end { let n = Int(raw[cursor] >> 4), t = raw[cursor] & 15; cursor += 1; tags.append("tag\(t)=" + hex(raw[cursor..<min(end, cursor + n)])); cursor += n }
                        let line = "len=\(raw.count) connectable=\(frame["connectable"] ?? "?") " + tags.joined(separator: " ") + (raw.count > end ? " tail=" + hex(raw[end...]) : "")
                        if seen.insert(line).inserted { print(line) }
                    }
                    print("frames: \(discovery.samsungFrames.count), distinct contexts for peer: \(seen.count)"); exit(0)
                }
                RunLoop.main.run(); return
            }
            if command == "lan-serve" {
                // Advertise this Mac to Galaxy PCs; announce optional text to each device that connects.
                let presence = LANPresence(profile: try profile ?? ProfileStore.load())
                presence.status = { print($0); fflush(stdout) }; presence.trace = { print($0); fflush(stdout) }
                let text = args.firstIndex(of: "--text").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
                presence.opened = { session in
                    session.status = { print($0); fflush(stdout) }; session.trace = { print($0); fflush(stdout) }
                    if let text { Task { try? await Task.sleep(nanoseconds: 1_000_000_000); try? await session.publish(text) } }
                }
                try presence.start()
                if args.contains("--dial") { presence.connectPCs() }
                let seconds = args.firstIndex(of: "--seconds").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 60
                DispatchQueue.main.asyncAfter(deadline: .now() + min(600, seconds)) { presence.stop(); exit(0) }
                RunLoop.main.run(); return
            }
            if command == "clip-push", args.count >= 5, let port = UInt16(args[3]), port != 0 {
                // Announce text or an image file to one LAN peer (for example a Galaxy Book) and serve its requests (default 20 s).
                var selected = try profile ?? ProfileStore.load()
                if let i = args.firstIndex(of: "--peer"), i + 1 < args.count { selected.preferredPeerAddress = args[i + 1] }
                let session = ClipboardSession(connection: MCFTransport(host: args[2], port: port), profile: selected)
                session.status = { print($0); fflush(stdout) }; session.trace = { print($0); fflush(stdout) }
                Task {
                    do {
                        try await session.connect()
                        let runner = Task { try await session.run() }
                        if let image = FileManager.default.contents(atPath: args[4]) {
                            let ext = (args[4] as NSString).pathExtension.lowercased()
                            try await session.publishImage(image, fileName: ext == "jpg" || ext == "jpeg" ? "image.jpg" : "image.png")
                        } else { try await session.publish(args[4]) }
                        let seconds = args.firstIndex(of: "--seconds").flatMap { $0 + 1 < args.count ? UInt64(args[$0 + 1]) : nil } ?? 20
                        try await Task.sleep(nanoseconds: min(seconds, 300) * 1_000_000_000); runner.cancel(); session.stop(); exit(0)
                    } catch { print("clip-push failed: " + error.localizedDescription); exit(1) }
                }
                RunLoop.main.run(); return
            }
            if command == "probe", args.count >= 4, let port = UInt16(args[3]), port != 0 {
                var selectedProfile = try profile ?? ProfileStore.load()
                if let i = args.firstIndex(of: "--peer"), i + 1 < args.count { selectedProfile.preferredPeerAddress = args[i + 1] }
                Task {
                    let transport = MCFTransport(host: args[2], port: port)
                    defer { transport.cancel() }
                    do {
                        let session = try await transport.authenticate(profile: selectedProfile)
                        print("Account authentication completed; ECDH session key established; peer is in the imported device list. Borrowed Windows identity: \(selectedProfile.borrowedIdentity).")
                        guard session.sessionKey?.count == 32 else { throw ContinuityError.message("Invalid session key.") }
                        exit(0)
                    } catch { fputs(("Probe failed: " + error.localizedDescription + "\n"), stderr); exit(1) }
                }
                RunLoop.main.run(); return
            }
            print("continuity v1.1-beta.4\n  scan [--seconds 12] [--profile-stdin]\n  probe HOST PORT [--profile-stdin]\n  import-profile --profile-stdin\nProfiles are read from stdin or Keychain; never put keys in arguments.")
        } catch {
            let message = error.localizedDescription + "\n"; fputs(message, stderr)
            if let i = args.firstIndex(of: "--output"), i + 1 < args.count { try? message.write(toFile: args[i + 1], atomically: true, encoding: .utf8) }
            exit(1)
        }
    }
}
