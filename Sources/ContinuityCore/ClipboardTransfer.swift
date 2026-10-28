import Foundation
import Network
import ImageIO

/// The data socket uses the account handshake, then length-prefixed ProtoData.
/// All clipboard bytes stay in memory; a peer URI is never a local file path.
enum ClipboardDataWire {
    static let imageLimit = 32 * 1024 * 1024
    static func size(_ value: Int) -> Data { withUnsafeBytes(of: UInt64(value).bigEndian) { Data($0) } }
    static func size(_ data: Data) throws -> Int {
        guard data.count == 8 else { throw ContinuityError.message("Invalid clipboard length.") }
        let value = data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard value > 0, value <= imageLimit else { throw ContinuityError.message("Clipboard data exceeds the 32 MiB limit.") }
        return Int(value)
    }
    static func command(_ command: MCFCommand, key: Data) throws -> Data {
        ProtoWire.bytes(1, MCFPacket(handler: 2, payload: try MCFCrypto.cbc(command.encoded, key: key, encrypt: true)).encoded)
    }
    static func chunk(_ data: Data, key: Data) throws -> Data {
        guard data.count <= 524288 else { throw ContinuityError.message("Clipboard chunk is too large.") }
        return ProtoWire.bytes(2, ProtoWire.bytes(1, try MCFCrypto.cbc(data, key: key, encrypt: true)))
    }
    enum Item { case command(MCFCommand), chunk(Data) }
    static func decode(_ data: Data, key: Data) throws -> [Item] {
        let fields = try ProtoWire.fields(data)
        guard (fields[1]?.count ?? 0) + (fields[2]?.count ?? 0) <= 32 else { throw ContinuityError.message("Too many items in clipboard data packet.") }
        var result: [Item] = []
        for value in fields[1] ?? [] {
            guard case .bytes(let bytes) = value else { throw ContinuityError.message("Invalid clipboard command envelope.") }
            let packet = try MCFPacket(data: bytes)
            guard packet.handler == 2 else { throw ContinuityError.message("Unexpected clipboard data handler.") }
            result.append(.command(try MCFCommand(data: MCFCrypto.cbc(packet.payload, key: key, encrypt: false))))
        }
        for value in fields[2] ?? [] {
            guard case .bytes(let bytes) = value else { throw ContinuityError.message("Invalid clipboard chunk envelope.") }
            let encrypted = ProtoWire.bytes(try ProtoWire.fields(bytes), 1)
            guard encrypted.count <= 524320 else { throw ContinuityError.message("Clipboard chunk exceeds its bound.") }
            result.append(.chunk(try MCFCrypto.cbc(encrypted, key: key, encrypt: false)))
        }
        guard !result.isEmpty, result.count <= 32 else { throw ContinuityError.message("Invalid clipboard data packet.") }
        return result
    }
    static func validateImage(_ data: Data) throws {
        guard !data.isEmpty, data.count <= imageLimit,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16384, height <= 16384,
              width <= 40_000_000 / height else { throw ContinuityError.message("Clipboard image is invalid or exceeds 40 megapixels.") }
    }
}

struct ClipboardURI: Codable {
    var relativePath: String
    var uri: String
    var size: Int
    var isFolder: Bool
}

@MainActor final class ClipboardTransfer {
    enum Job { case image(UInt8), metadata(UInt8, Int), upload(UInt8, Data, String), metadataUpload(UInt8, Data), rawUpload(UInt8, Data), clipDownload(UInt8, Int) }
    private let profile: ContinuityProfile
    private weak var session: ClipboardSession?
    private var listener: NWListener?
    private var pending: [String: Job] = [:]
    private var sockets: [UUID: MCFTransport] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var feature: FeatureSession?
    private var connectingFeature = false
    private var stopped = false
    var localImage: (sequence: UInt8, bytes: Data, uri: String)?
    var localMetadata: (sequence: UInt8, bytes: Data)?
    /// Set after answering GET_CLIP with a length; the next phone data channel streams it.
    var rawUpload: (sequence: UInt8, bytes: Data)?
    var receivedImage: ((Data, UInt8) -> Void)?
    var receivedMetadata: ((Data, UInt8) -> Void)?
    var receivedClip: ((Data, UInt8) -> Void)?
    var status: ((String) -> Void)?
    init(profile: ContinuityProfile, session: ClipboardSession) { self.profile = profile; self.session = session }
    func stop() {
        stopped = true; listener?.cancel(); listener = nil
        feature?.disconnect(); feature = nil
        sockets.values.forEach { $0.cancel() }; sockets = [:]
        tasks.values.forEach { $0.cancel() }; tasks = [:]; pending = [:]
        localImage = nil; localMetadata = nil; rawUpload = nil
    }
    private func launch(_ operation: @escaping () async throws -> Void) {
        guard !stopped else { return }
        let id = UUID()
        tasks[id] = Task { [weak self] in
            defer { self?.tasks.removeValue(forKey: id) }
            do { try await operation() }
            catch { if self?.stopped == false { self?.status?("Clipboard transfer: " + error.localizedDescription) } }
        }
    }
    func acceptFeatureRequest() {
        guard !connectingFeature, feature?.isConnected != true else { return }
        connectingFeature = true
        launch { [weak self] in
            guard let self, let session else { return }
            defer { connectingFeature = false }
            feature?.disconnect()
            let link = FeatureSession(appID: 102); feature = link
            link.status = { [weak self] in self?.status?($0) }
            do { try await link.acceptClipboardRequest(profile: profile, sharing: session) }
            catch { link.disconnect(); feature = nil; throw error }
        }
    }
    func prepareUpload(sequence: UInt8, reply: ((UInt64, MCFCommand) async throws -> Void)? = nil) {
        guard !connectingFeature else { return }
        connectingFeature = true
        launch { [weak self] in
            guard let self, let session else { return }
            defer { connectingFeature = false }
            func respond(_ result: UInt8) async throws {
                let command = MCFCommand(id: 6, type: 2, payload: Data([result]))
                if let reply { try await reply(2, command) }
                else { try await session.sendControl(handler: 2, command: command) }
            }
            guard localImage?.sequence == sequence || localMetadata?.sequence == sequence else {
                try await respond(11); return
            }
            do {
                if feature?.isConnected != true {
                    feature?.disconnect()
                    let link = FeatureSession(appID: 102); feature = link
                    link.status = { [weak self] in self?.status?($0) }
                    try await link.connect(profile: profile, sharing: session)
                }
                try await respond(10)
            } catch {
                feature?.disconnect(); feature = nil
                try? await respond(11)
                throw error
            }
        }
    }
    func request(_ job: Job) {
        launch { [weak self] in
            guard let self else { return }
            // Prefer the Wi-Fi command link when it comes up quickly. The device
            // also accepts the data-channel request over Bluetooth, and does
            // not always offer a handover, so its absence is not an error.
            if case .image = job, (try? await session?.waitForWifiCommand(attempts: 30)) == nil {
                self.status?("No Wi-Fi command handover; requesting the image over Bluetooth.")
            }
            try await self.open(job)
        }
    }
    private func listeningPort() async throws -> UInt16 {
        if let port = listener?.port?.rawValue { return port }
        let value = try NWListener(using: .tcp, on: .any); listener = value
        value.newConnectionHandler = { [weak self] socket in Task { @MainActor in
            guard let self, !self.stopped, self.sockets.count < 2, !self.pending.isEmpty else { socket.cancel(); return }
            let transport = MCFTransport(socket: socket)
            self.launch { [weak self] in guard let self else { transport.cancel(); return }; try await self.accept(transport) }
        } }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var done = false
            value.stateUpdateHandler = { state in Task { @MainActor in
                guard !done else { return }
                switch state {
                case .ready: done = true; continuation.resume()
                case .failed(let error): done = true; continuation.resume(throwing: error)
                case .cancelled: done = true; continuation.resume(throwing: CancellationError())
                default: break
                }
            } }
            value.start(queue: .main)
        }
        guard let port = value.port?.rawValue else { throw ContinuityError.message("No clipboard data port.") }; return port
    }
    private func open(_ job: Job) async throws {
        guard let session, pending.count < 2 else { throw ContinuityError.message("Clipboard transfer is busy.") }
        let port = try await listeningPort()
        // Match the shipped client's four-hex-digit channel format. Account
        // authentication supplies authorization; this name only correlates jobs.
        var name: String
        repeat { name = String(UUID().uuidString.prefix(4)).lowercased() } while pending[name] != nil
        let networks = try FeatureProtocol.localNetworks(commandPort: port)
        let object: [String: Any] = ["ID": profile.localBluetoothAddress, "IP": "", "PT": 0,
            "ARRAY": networks, "CN": name, "HI": 2]
        pending[name] = job
        do {
            try await session.sendControl(handler: 100, command: MCFCommand(id: 2, type: 1, payload: JSONSerialization.data(withJSONObject: object)))
            status?("Requested an authenticated clipboard Wi-Fi transfer (Mac networks: \(FeatureProtocol.networkSummary(networks))).")
            launch { [weak self] in
                try await Task.sleep(nanoseconds: 20_000_000_000)
                if self?.pending.removeValue(forKey: name) != nil { self?.status?("The device did not open its clipboard data connection.") }
            }
        } catch { pending.removeValue(forKey: name); throw error }
    }
    func handle(_ command: MCFCommand, reply: ((UInt64, MCFCommand) async throws -> Void)? = nil) {
        guard let object = (try? JSONSerialization.jsonObject(with: command.payload)) as? [String: Any],
              let name = object["CN"] as? String, !name.isEmpty, name.utf8.count <= 128,
              name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return }
        if command.type == 2 {
            let code = object["RC"] as? Int ?? -1
            status?("Clipboard data-channel response code: \(code).")
            if code != 1 {
                pending.removeValue(forKey: name)
                // Device codes: 3 = no shared subnet, 4 = missing network info, 2 = other failure.
                status?(code == 3 ? "The device found no network shared with the Mac. Join the same Wi-Fi or the device's hotspot for images."
                                  : "The device declined the clipboard data channel.")
            }
            return
        }
        guard command.type == 1 else { return }
        launch { [weak self] in
            guard let self, let session else { return }
            let job: Job?
            if object["HI"] as? Int == 2, let raw = rawUpload { job = .rawUpload(raw.sequence, raw.bytes); rawUpload = nil }
            else if object["HI"] as? Int == 2, let image = localImage { job = .upload(image.sequence, image.bytes, image.uri) }
            else if object["HI"] as? Int == 2, let metadata = localMetadata { job = .metadataUpload(metadata.sequence, metadata.bytes) }
            else { job = nil }
            let endpoint = try? Self.endpoint(object, networks: FeatureProtocol.localNetworks())
            let approved = job != nil && endpoint != nil && sockets.count < 2
            let response = MCFCommand(id: 2, type: 2, payload: try JSONSerialization.data(withJSONObject: ["RC": approved ? 1 : 2, "CN": name]))
            if let reply { try await reply(100, response) }
            else { try await session.sendControl(handler: 100, command: response) }
            guard let job, let endpoint, approved else {
                status?("Declined the device's clipboard data-channel request (\(job == nil ? "nothing to send" : endpoint == nil ? "no shared network" : "busy")).")
                return
            }
            status?("Device requested a clipboard data channel; connecting to it.")
            let transport = MCFTransport(host: endpoint.0, port: endpoint.1)
            let id = UUID(); sockets[id] = transport
            defer { transport.cancel(); sockets.removeValue(forKey: id) }
            let deadline = Task { try? await Task.sleep(nanoseconds: 60_000_000_000); if !Task.isCancelled { transport.cancel() } }; defer { deadline.cancel() }
            let auth = try await transport.authenticate(profile: profile, channel: name)
            guard let key = auth.sessionKey else { throw ContinuityError.message("No clipboard transfer key.") }
            try await exchange(transport, key: key, job: job)
        }
    }
    nonisolated static func endpoint(_ object: [String: Any], networks: [[String: Any]]) throws -> (String, UInt16) {
        func number(_ text: String) -> UInt32? {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            let bytes = parts.compactMap { UInt8($0) }
            guard bytes.count == 4, zip(parts, bytes).allSatisfy({ String($0.0) == String($0.1) }) else { return nil }
            return bytes.reduce(0) { $0 << 8 | UInt32($1) }
        }
        for network in object["ARRAY"] as? [[String: Any]] ?? [] {
            guard let host = network["IP"] as? String, let remote = number(host),
                  remote >> 24 != 0, remote >> 24 != 127, remote >> 16 != 0xa9fe, remote >> 28 < 14,
                  let raw = network["LPT"] as? Int, let port = UInt16(exactly: raw), port > 0 else { continue }
            if networks.contains(where: { local in
                guard let ip = local["IP"] as? String, let maskText = local["MASK"] as? String,
                      let address = number(ip), let mask = number(maskText), mask != 0 else { return false }
                return address != remote && address & mask == remote & mask
            }) { return (host, port) }
        }
        throw ContinuityError.message("Clipboard data endpoint is outside the Mac's directly attached network.")
    }
    private func accept(_ transport: MCFTransport) async throws {
        let id = UUID(); sockets[id] = transport
        defer { transport.cancel(); sockets.removeValue(forKey: id) }
        let deadline = Task { try? await Task.sleep(nanoseconds: 60_000_000_000); if !Task.isCancelled { transport.cancel() } }; defer { deadline.cancel() }
        try await transport.connect()
        let auth = try MCFResponder(profile: profile)
        try await transport.send(auth.reply(to: transport.receive()))
        guard let name = auth.requestedChannel, let job = pending.removeValue(forKey: name) else { throw ContinuityError.message("Unrequested clipboard data connection.") }
        try auth.finish(await transport.receive())
        status?("Device opened an account-authenticated clipboard data socket.")
        guard let key = auth.sessionKey else { throw ContinuityError.message("No clipboard data session key.") }
        try await exchange(transport, key: key, job: job)
    }
    private func exchange(_ transport: MCFTransport, key: Data, job: Job) async throws {
        func send(_ id: UInt64, _ type: UInt64, _ payload: Data = Data()) async throws {
            try await transport.sendFrame(ClipboardDataWire.command(MCFCommand(id: id, type: type, payload: payload), key: key))
        }
        func chunks(_ data: Data) async throws {
            for begin in stride(from: 0, to: data.count, by: 524288) {
                try Task.checkCancellation()
                try await transport.sendFrame(ClipboardDataWire.chunk(data.subdata(in: begin..<min(begin + 524288, data.count)), key: key))
            }
        }
        var bytes = Data(), expected: Int?, uriList = true, clipSequence: UInt8 = 0
        func finishImage() async throws {
            guard bytes.count == expected else { throw ContinuityError.message("Clipboard image was truncated.") }
            try ClipboardDataWire.validateImage(bytes)
            try await send(3, 1, Data([clipSequence, 1])); receivedImage?(bytes, clipSequence)
        }
        switch job {
        case .image(let sequence): clipSequence = sequence; try await send(8, 1, Data([sequence]))
        case .metadata(let sequence, let size), .clipDownload(let sequence, let size): clipSequence = sequence; expected = size; uriList = false
        case .metadataUpload(_, let data): try await chunks(data)
        case .rawUpload(_, let data): try await chunks(data); status?("Streamed the Mac image; waiting for device confirmation.")
        case .upload: break
        }
        while !Task.isCancelled {
            for item in try ClipboardDataWire.decode(await transport.receiveFrame(), key: key) {
                switch item {
                case .chunk(let data):
                    let limit = uriList ? 1_048_576 : expected ?? 0
                    guard data.count <= limit - bytes.count else { throw ContinuityError.message("Clipboard transfer exceeded its declared length.") }
                    bytes += data
                    if case .metadata = job, bytes.count == expected {
                        try await send(3, 1, Data([clipSequence, 1])); receivedMetadata?(bytes, clipSequence); return
                    }
                    if case .clipDownload = job, bytes.count == expected {
                        try await send(3, 1, Data([clipSequence, 1])); receivedClip?(bytes, clipSequence); return
                    }
                    // Like Samsung's own downloader, complete on the announced length.
                    if case .image = job, !uriList, bytes.count == expected { try await finishImage(); return }
                case .command(let command):
                    if command.id == 3, command.type == 1 {
                        switch job {
                        case .upload(let sequence, _, _), .metadataUpload(let sequence, _), .rawUpload(let sequence, _):
                            guard command.payload == Data([sequence, 1]) else { throw ContinuityError.message("The device did not confirm a successful clipboard download.") }
                            status?("Device confirmed the clipboard transfer completed.")
                        default: break
                        }
                        try await send(3, 2, Data(command.payload.prefix(1))); return
                    }
                    switch job {
                    case .upload(let sequence, let data, let uri):
                        if command.id == 8, command.type == 1, command.payload == Data([sequence]) {
                            try await chunks(JSONEncoder().encode([ClipboardURI(relativePath: String(uri.split(separator: "/").last ?? "image.png"), uri: uri, size: data.count, isFolder: false)]))
                            status?("Sent the clipboard file list to the device.")
                            try await send(8, 2, Data([sequence, 0]))
                        } else if command.id == 5, command.type == 1 {
                            guard command.payload == Data(uri.utf8) else { throw ContinuityError.message("The peer requested a different clipboard URI.") }
                            try await send(5, 2, Data([16]) + ClipboardDataWire.size(data.count))
                            try await chunks(data)
                            try await send(5, 2, Data([0]) + ClipboardDataWire.size(0))
                            status?("Transferred Mac clipboard image bytes; waiting for device confirmation.")
                        }
                    case .image:
                        if command.id == 8, command.type == 2 {
                            guard command.payload.count >= 2, command.payload.first == clipSequence, [0, 16].contains(command.payload[command.payload.startIndex + 1]),
                                  let entries = try? JSONDecoder().decode([ClipboardURI].self, from: bytes), entries.count == 1,
                                  let entry = entries.first, !entry.isFolder, entry.size > 0, entry.size <= ClipboardDataWire.imageLimit,
                                  !entry.uri.isEmpty, entry.uri.utf8.count <= 4096 else { throw ContinuityError.message("The clipboard does not contain a single supported image.") }
                            bytes = Data(); uriList = false; expected = entry.size
                            try await send(5, 1, Data(entry.uri.utf8))
                        } else if command.id == 5, command.type == 2 {
                            // [code] + big-endian length: 16 starts with the real length;
                            // 0 ends the task with length 0; anything else is a phone error.
                            guard !uriList, command.payload.count == 9, let code = command.payload.first else { throw ContinuityError.message("Invalid clipboard file header.") }
                            switch code {
                            case 16:
                                guard bytes.isEmpty else { throw ContinuityError.message("Duplicate clipboard file header.") }
                                expected = try ClipboardDataWire.size(Data(command.payload.dropFirst()))
                            case 0:
                                try await finishImage(); return
                            default:
                                throw ContinuityError.message("The device could not send the clipboard image (code \(code)).")
                            }
                        }
                    case .metadata, .metadataUpload, .rawUpload, .clipDownload: break
                    }
                }
            }
        }
    }
}
