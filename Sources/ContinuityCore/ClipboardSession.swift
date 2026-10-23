import Foundation
import zlib
import CryptoKit

public enum ClipboardCompression {
    public static func gzip(_ data: Data, decompress: Bool = false) throws -> Data {
        guard data.count <= 1_048_576 else { throw ContinuityError.message("Clipboard metadata exceeds the size limit.") }
        var stream = z_stream()
        let code = decompress ? inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) : deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard code == Z_OK else { throw ContinuityError.message("Could not initialize clipboard compression.") }
        defer { if decompress { inflateEnd(&stream) } else { deflateEnd(&stream) } }
        var output = Data(count: 1_048_576)
        let result = data.withUnsafeBytes { input in output.withUnsafeMutableBytes { out in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress); stream.avail_in = uInt(data.count)
            stream.next_out = out.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = 1_048_576
            return decompress ? inflate(&stream, Z_FINISH) : deflate(&stream, Z_FINISH)
        } }
        guard result == Z_STREAM_END, stream.avail_in == 0 else { throw ContinuityError.message("Invalid or oversized compressed clipboard metadata.") }
        output.count = Int(stream.total_out); return output
    }
}

public enum ClipboardContext {
    public static func eventSequence(_ data: Data) throws -> UInt8? { try event(data)?.sequence }
    public static func event(_ data: Data) throws -> (sequence: UInt8, kind: UInt8, flags: UInt8)? {
        let raw = Array(data)
        guard raw.count >= 16, raw[13] & 15 == 1 else { return nil }
        let start = Int(raw[14]), length = Int(raw[15])
        guard start <= raw.count, length <= raw.count - start else { throw ContinuityError.message("Invalid context boundaries.") }
        var i = start
        while i < start + length {
            let count = Int(raw[i] >> 4), tag = raw[i] & 15; i += 1
            guard count <= start + length - i else { throw ContinuityError.message("Truncated continuity context.") }
            if tag == 2, count == 4, raw[i] == 2, (1...5).contains(raw[i + 2]) { return (raw[i + 1], raw[i + 2], raw[i + 3]) }
            i += count
        }
        return nil
    }
    public static func make(profile: ContinuityProfile, sequence: UInt8?, contextSequence: UInt8, kind: UInt8 = 1, flags: UInt8 = 2) throws -> Data {
        // Embedded context travels inside the authenticated command connection;
        // Samsung sends the raw, unobfuscated LTV form in CommandPacket field 4.
        var ltv = Data([0x51, 0, 0, 10, 7, 5])
        if let sequence { ltv += Data([0x42, 2, sequence, kind, flags]) }
        let local = try ContinuityProfile.addressBytes(profile.localBluetoothAddress)
        ltv += Data([0x44, contextSequence & 63]) + local.suffix(3)
        var header = Data([2, 24, 0, 0, 0x65]) + Data(repeating: 0, count: 8)
        header += Data([0x21, 16, UInt8(ltv.count)])
        return header + ltv
    }
}

@MainActor public final class ClipboardSession {
    public let connection: MCFConnection
    private let profile: ContinuityProfile
    private var key = Data()
    private var clientHandlers: [UUID: (MCFCommand) -> Void] = [:]
    private var transfer: ClipboardTransfer?
    private var handover: CommandHandover?
    private var localKind: UInt8 = 1
    private var activeRemote: UInt8?
    private var suppressedSequence: UInt8?
    private var waitingImage: UInt8?
    private var waitingMetadata: (UInt8, Int)?
    public var receivedImage: ((Data) -> Void)?
    /// The app's master switch gates clipboard traffic while keeping feature/control replies alive.
    public var clipboardEnabled = true {
        didSet {
            guard clipboardEnabled != oldValue else { return }
            if clipboardEnabled { if !key.isEmpty { installTransfer() }; return }
            activeRemote = nil; waitingImage = nil; waitingMetadata = nil; pendingRemote = nil; pendingGetClip = nil
            localClip = nil; transfer?.stop()
        }
    }
    public var eagerImages = true
    /// Diagnostic: fetch phone images with GET_CLIP to capture Samsung Keyboard's archive.
    public var captureClipArchives = false
    public var capturedClip: ((Data) -> Void)?
    private var pendingGetClip: UInt8?
    func addClientHandler(_ callback: @escaping (MCFCommand) -> Void) -> UUID { let token = UUID(); clientHandlers[token] = callback; return token }
    func removeClientHandler(_ token: UUID) { clientHandlers.removeValue(forKey: token) }
    func sendControl(handler: UInt64, command: MCFCommand) async throws { try await send(handler: handler, command: command) }
    private var packetSequence: UInt64 = 0
    private var localSequence: UInt8 = 0
    private var localClip: ClipboardText?
    private var lastRequested: UInt8?
    private var pendingRemote: UInt8?
    private var publishedAt = Date.distantPast
    private var guardState = ClipboardLoopGuard()
    private var contextSequence: UInt8
    private let preferenceKey: String
    public var trace: ((String) -> Void)?
    public var received: ((ClipboardText) -> Void)?
    public var status: ((String) -> Void)?
    public var hotspotReceived: ((HotspotCredentials) -> Void)?
    public var clientCommandReceived: ((MCFCommand) -> Void)?
    public var tcpOfferReceived: ((Data) -> Void)?
    public func applicationKey(_ appID: UInt8) throws -> Data {
        if let handover, handover.isReady { return try handover.applicationKey(appID) }
        return try FeatureProtocol.applicationKey(sessionKey: key, appID: appID)
    }
    public func sendClientCommand(_ command: MCFCommand) async throws { try await send(handler: 6, command: command) }
    public init(connection: MCFConnection, profile: ContinuityProfile) {
        self.connection = connection; self.profile = profile
        preferenceKey = "continuity-sequence-" + Data(SHA256.hash(data: Data(profile.localBluetoothAddress.utf8))).prefix(8).hexString
        contextSequence = UInt8(clamping: UserDefaults.standard.object(forKey: preferenceKey + "-context") as? Int ?? 31)
        localSequence = UInt8(clamping: UserDefaults.standard.object(forKey: preferenceKey + "-clip") as? Int ?? 1)
        if let bluetooth = connection as? BLEMCFTransport {
            bluetooth.contextChanged = { [weak self] context in
                Task { @MainActor [weak self] in
                    do { try await self?.observe(context, advertisement: true) } catch { self?.status?(error.localizedDescription) }
                }
            }
        }
    }
    public func connect() async throws {
        let auth = try await connection.authenticate(profile: profile)
        guard let key = auth.sessionKey else { throw ContinuityError.message("Authentication did not create a session key.") }
        try await start(key: key, peer: auth.authenticatedPeer, address: auth.authenticatedAddress)
    }
    /// The authenticated device's Bluetooth identity.
    public private(set) var peerAddress: String?
    /// Starts on an authenticated connection, including one a Galaxy PC opened to this Mac.
    func start(key: Data, peer: String?, address: String?) async throws {
        self.key = key; peerAddress = address
        let handover = CommandHandover(profile: profile, session: self); self.handover = handover
        handover.status = { [weak self] in self?.status?($0) }
        if clipboardEnabled { installTransfer() }
        status?("Authenticated directly with \(peer ?? "Samsung device").")
        try await send(handler: 100, command: MCFCommand(id: 3, type: 1, payload: Data([1])))
        try await send(handler: 100, command: MCFCommand(id: 9, type: 1))
        if let context = (connection as? BLEMCFTransport)?.lastContext {
            trace?("Initial phone context: \(Self.contextShape(context))")
            try await observe(context, advertisement: true)
        }
    }
    private func installTransfer() {
        let transfer = ClipboardTransfer(profile: profile, session: self); self.transfer = transfer
        transfer.status = { [weak self] in self?.status?($0) }
        transfer.receivedImage = { [weak self] data, sequence in
            guard let self, self.clipboardEnabled, self.activeRemote == sequence else { return }
            self.activeRemote = nil; self.receivedImage?(data); self.status?("Received phone clipboard image (\(data.count) bytes).")
        }
        transfer.receivedClip = { [weak self] data, _ in self?.capturedClip?(data) }
        transfer.receivedMetadata = { [weak self] data, sequence in
            guard self?.clipboardEnabled == true, self?.activeRemote == sequence else { return }
            do { try self?.receiveMetadata(data) } catch { self?.status?(error.localizedDescription) }
        }
    }
    public func publish(_ text: String, html: String? = nil) async throws {
        guard clipboardEnabled else { return }
        guard !key.isEmpty else { throw ContinuityError.message("Connect before sending clipboard text.") }
        guard text.utf8.count + (html?.utf8.count ?? 0) <= 900000 else { throw ContinuityError.message("Clipboard text and HTML exceed the metadata limit.") }
        guard guardState.shouldPublish(text) else { return }
        var clip = ClipboardText(text: text, source: profile.localBluetoothAddress); clip.html = html
        if html != nil { clip.type = "HTML" }
        activeRemote = nil; waitingImage = nil; waitingMetadata = nil
        localKind = html == nil ? 1 : 2; transfer?.localImage = nil; transfer?.rawUpload = nil
        localClip = clip; localSequence = localSequence >= 254 ? 1 : localSequence + 1
        transfer?.localMetadata = (localSequence, try ClipboardCompression.gzip(clip.encoded()))
        publishedAt = Date()
        UserDefaults.standard.set(Int(localSequence), forKey: preferenceKey + "-clip")
        try await send(handler: 2, command: MCFCommand(id: 255, type: 3))
        status?("Announced Mac text. Waiting for the phone's metadata request…")
    }
    public func publishImage(_ data: Data, fileName: String = "image.png") async throws {
        guard clipboardEnabled else { return }
        guard !key.isEmpty else { throw ContinuityError.message("Connect before sending clipboard images.") }
        try ClipboardDataWire.validateImage(data)
        guard ["image.png", "image.jpg", "image.heic"].contains(fileName) else { throw ContinuityError.message("Unsupported clipboard image name.") }
        activeRemote = nil; waitingImage = nil; waitingMetadata = nil
        let uri = "galaxy-clipboard://" + UUID().uuidString + "/" + fileName
        var clip = ClipboardText(text: "", source: profile.localBluetoothAddress); clip.type = "FILE"
        clip.files = [ClipboardFile(uri: uri, name: fileName, size: data.count)]
        // Kind 4 (IMAGE), as between Galaxy phones: the phone fetches eagerly with
        // GET_CLIP and Samsung Keyboard sets a real image clip from the archive.
        // Kind 3 (URI) is what Samsung's PC client sends; it only leaves a
        // placeholder that Samsung's own file-aware apps can paste.
        localSequence = localSequence >= 254 ? 1 : localSequence + 1; localClip = clip; localKind = eagerImages ? 4 : 3
        transfer?.localImage = (localSequence, data, uri)
        transfer?.localMetadata = (localSequence, try ClipboardCompression.gzip(clip.encoded()))
        publishedAt = Date(); UserDefaults.standard.set(Int(localSequence), forKey: preferenceKey + "-clip")
        try await send(handler: 2, command: MCFCommand(id: 255, type: 3))
        status?("Announced Mac image. Waiting for the phone's transfer request…")
    }
    private func receiveMetadata(_ compressed: Data) throws {
        guard clipboardEnabled else { return }
        let json = try ClipboardCompression.gzip(compressed, decompress: true)
        let clip = try JSONDecoder().decode(ClipboardText.self, from: json)
        if ["TEXT", "HTML"].contains(clip.type) {
            if guardState.received(clip) { received?(clip) }
        } else if let sequence = lastRequested, ["FILE", "IMAGE", "URI", "URI_LIST"].contains(clip.type) {
            waitingImage = sequence
            Task { try? await self.send(handler: 2, command: MCFCommand(id: 6, type: 1, payload: Data([sequence]))) }
        } else { status?("The phone copied an unsupported clipboard type: \(clip.type).") }
    }
    public func requestHotspot() async throws {
        guard !key.isEmpty else { throw ContinuityError.message("Connect before requesting Auto Hotspot.") }
        try await send(handler: 6, command: MCFCommand(id: 3, type: 3, payload: Data([4, 0]) + HotspotCredentials.request()))
        status?("Requested Samsung Auto Hotspot. Waiting for the phone…")
    }
    private func observe(_ context: Data, advertisement: Bool = false) async throws {
        guard !key.isEmpty, let event = try ClipboardContext.event(context), event.sequence != 0, lastRequested != event.sequence || (advertisement && suppressedSequence == event.sequence) else { return }
        let sequence = event.sequence
        trace?("CLIPBOARD EVENT sequence=\(sequence) kind=\(event.kind) flags=\(event.flags)")
        lastRequested = sequence
        guard clipboardEnabled else { return }
        // Do not replace a fresh local copy with an older peer context attached
        // to its metadata request. A subsequent phone copy has a new sequence.
        guard advertisement || Date().timeIntervalSince(publishedAt) >= 2 else { suppressedSequence = sequence; return }
        suppressedSequence = nil
        activeRemote = sequence
        if event.kind == 4, captureClipArchives {
            pendingGetClip = sequence
            try await send(handler: 2, command: MCFCommand(id: 1, type: 1, payload: Data([sequence]))); return
        }
        if event.kind >= 3 {
            waitingImage = sequence
            try await send(handler: 2, command: MCFCommand(id: 6, type: 1, payload: Data([sequence]))); return
        }
        pendingRemote = sequence
        try await send(handler: 2, command: MCFCommand(id: 4, type: 1, payload: Data([sequence])))
    }
    private func send(handler: UInt64, command: MCFCommand) async throws {
        guard handler != 2 || clipboardEnabled else { return }
        packetSequence += 1
        contextSequence = contextSequence >= 62 ? 1 : contextSequence + 1
        UserDefaults.standard.set(Int(contextSequence), forKey: preferenceKey + "-context")
        trace?("SEND handler=\(handler) command=\(command.id) type=\(command.type) bytes=\(command.payload.count)")
        let context = try ClipboardContext.make(profile: profile, sequence: localClip == nil ? nil : localSequence, contextSequence: contextSequence, kind: localKind, flags: (transfer?.localMetadata?.bytes.count ?? 0) >= 20480 ? 6 : 2)
        if let handover, handover.isReady {
            try await handover.send(handler: handler, command: command, context: context); return
        }
        try await connection.send(MCFPacket(handler: handler, sequence: packetSequence, payload: MCFCrypto.cbc(command.encoded, key: key, encrypt: true), advPayload: context, accountRevision: profile.revision))
    }
    public func run() async throws {
        trace?("Authenticated command reader started.")
        while !Task.isCancelled {
            let packet = try await connection.receive()
            let command = try MCFCommand(data: MCFCrypto.cbc(packet.payload, key: key, encrypt: false))
            try await handleIncoming(handler: packet.handler, command: command, context: packet.advPayload)
        }
    }
    private static func contextShape(_ data: Data) -> String {
        let raw = Array(data)
        guard raw.count >= 16 else { return "short" }
        var cursor = Int(raw[14]); let end = cursor + Int(raw[15]); var shapes: [String] = []
        guard cursor >= 16, end <= raw.count else { return "invalid bounds" }
        while cursor < end {
            let length = Int(raw[cursor] >> 4), tag = raw[cursor] & 15; cursor += 1
            guard cursor + length <= end else { return "truncated LTV" }
            var text = "tag\(tag):\(length)"
            if tag == 2, length >= 2 { text += ":handler\(raw[cursor])" }
            shapes.append(text); cursor += length
        }
        return shapes.joined(separator: ",")
    }
    func handleIncoming(handler: UInt64, command: MCFCommand, context: Data, reply: ((UInt64, MCFCommand) async throws -> Void)? = nil) async throws {
        func send(handler: UInt64, command: MCFCommand) async throws {
            if let reply { try await reply(handler, command) }
            else { try await self.send(handler: handler, command: command) }
        }
        trace?("RECEIVE handler=\(handler) command=\(command.id) type=\(command.type) bytes=\(command.payload.count) contextBytes=\(context.count)")
        try await observe(context)
        if clipboardEnabled, handler == 6, command.id == 1, command.type == 1, command.payload.first == 102 { transfer?.acceptFeatureRequest() }
        if handler == 6 { clientCommandReceived?(command); for callback in Array(clientHandlers.values) { callback(command) } }
        if handler == 100 {
            if command.id == 2 { if clipboardEnabled { transfer?.handle(command, reply: reply) }; return }
            if command.type == 1 && [6, 9].contains(command.id) { try await send(handler: 100, command: MCFCommand(id: command.id, type: 2)) }
            else if command.type == 1 && command.id == 1 {
                tcpOfferReceived?(command.payload)
                let object = (try? JSONSerialization.jsonObject(with: command.payload)) as? [String: Any]
                var result = 2
                if let handover {
                    do { try handover.offer(command.payload); result = 1; status?("Accepted Samsung's Wi-Fi command handover offer.") }
                    catch { status?("Wi-Fi command offer: " + error.localizedDescription) }
                }
                let response = try JSONSerialization.data(withJSONObject: ["RC": result, "CN": object?["CN"] ?? NSNull()])
                try await send(handler: 100, command: MCFCommand(id: command.id, type: 2, payload: response))
            }
            return
        }
        if handler == 6 && command.id == 3 {
            let bytes = Array(command.payload)
            if bytes.count > 2, bytes[0] == 4, bytes[1] == 0 {
                let value = try JSONDecoder().decode(HotspotCredentials.self, from: Data(bytes.dropFirst(2)))
                if value.messagetype == 4 { hotspotReceived?(value) }
            }
            return
        }
        guard handler == 2, clipboardEnabled else { return }
        if command.id == 1, command.type == 1, let sequence = command.payload.first {
            // GET_CLIP: [id, 1] + bytes inline below 20 KiB, else [id, 7] + length
            // and the phone opens a data channel that carries only raw chunks.
            guard sequence == localSequence, let image = transfer?.localImage, image.sequence == sequence else {
                try await send(handler: 2, command: MCFCommand(id: 1, type: 2, payload: Data([sequence, 4, localSequence]))); return
            }
            let archive = KeyboardClipArchive.make(image: image.bytes, fileName: String(image.uri.split(separator: "/").last ?? "image.png"))
            if archive.count < 20480 {
                try await send(handler: 2, command: MCFCommand(id: 1, type: 2, payload: Data([sequence, 1]) + archive))
            } else {
                transfer?.rawUpload = (sequence, archive)
                try await send(handler: 2, command: MCFCommand(id: 1, type: 2, payload: Data([sequence, 7]) + ClipboardDataWire.size(archive.count)))
            }
            status?("The phone requested the Mac image (\(image.bytes.count) bytes, \(archive.count)-byte keyboard archive).")
        } else if command.id == 1, command.type == 2, command.payload.count >= 2, command.payload.first == pendingGetClip {
            pendingGetClip = nil
            let sequence = command.payload[command.payload.startIndex], code = command.payload[command.payload.startIndex + 1]
            let rest = Data(command.payload.dropFirst(2))
            status?("GET_CLIP response code \(code).")
            if code == 1 { capturedClip?(rest) }
            else if code == 7 { transfer?.request(.clipDownload(sequence, try ClipboardDataWire.size(rest))) }
        } else if command.id == 6, command.type == 1, let sequence = command.payload.first {
            transfer?.prepareUpload(sequence: sequence, reply: reply)
        } else if command.id == 6, command.type == 2 {
            guard command.payload.first == 10 else { waitingImage = nil; waitingMetadata = nil; status?("The phone could not open its clipboard Wi-Fi session (code \(command.payload.first.map(String.init) ?? "none"))."); return }
            if let value = waitingMetadata { waitingMetadata = nil; transfer?.request(.metadata(value.0, value.1)) }
            else if let sequence = waitingImage { waitingImage = nil; transfer?.request(.image(sequence)) }
        } else if command.id == 7, command.type == 3 { try receiveMetadata(command.payload)
        } else if command.id == 4 && command.type == 1, let sequence = command.payload.first {
            if sequence == localSequence, let localClip {
                let compressed = try ClipboardCompression.gzip(localClip.encoded())
                let response = compressed.count < 20480 ? Data([sequence, 8]) + compressed : Data([sequence, 7]) + ClipboardDataWire.size(compressed.count)
                try await send(handler: 2, command: MCFCommand(id: 4, type: 2, payload: response))
                status?("Sent clipboard metadata in response to the phone's request.")
            } else { try await send(handler: 2, command: MCFCommand(id: 4, type: 2, payload: Data([sequence, 9]))) }
        } else if command.id == 4 && command.type == 2 {
            let payload = Array(command.payload)
            guard payload.first == pendingRemote, payload.count >= 2 else { return }
            pendingRemote = nil
            if payload[1] == 8 { try receiveMetadata(Data(payload.dropFirst(2))) }
            else if payload[1] == 7, let sequence = payload.first {
                let size = try ClipboardDataWire.size(Data(payload.dropFirst(2)))
                guard size <= 1_048_576 else { throw ContinuityError.message("Clipboard metadata is too large.") }
                transfer?.request(.metadata(sequence, size))
            } else { status?("The phone has no clipboard metadata available.") }
        }
    }
    func waitForWifiCommand(attempts: Int = 150) async throws {
        for _ in 0..<attempts {
            try Task.checkCancellation()
            if handover?.isReady == true { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ContinuityError.message("The phone's Wi-Fi command handover did not authenticate.")
    }
    public func stop() { transfer?.stop(); transfer = nil; handover?.stop(); handover = nil; clientHandlers = [:]; connection.cancel(); key = Data() }
}
