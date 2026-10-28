import SwiftUI
import AppKit
import ImageIO
import Network
import ServiceManagement
import UniformTypeIdentifiers
@preconcurrency import UserNotifications
import Combine
import ContinuityCore
import Darwin

enum ConnectionVisualState: Equatable {
    case signedOut
    case searching
    case connecting(String)
    case connected(String)
    case reconnecting(attempt: Int, secondsRemaining: Int)
    case paused
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case home = "Home"
    case clipboard = "Clipboard"
    case calls = "Phone Calls"
    case buds = "Galaxy Buds"
    case nearby = "Nearby Devices"
    case multiControl = "Multi Control"
    case hotspots = "Auto Hotspot"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: return "sparkles.rectangle.stack.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .calls: return "phone.fill"
        case .buds: return "earbuds"
        case .nearby: return "dot.radiowaves.left.and.right"
        case .multiControl: return "rectangle.connected.to.line.below"
        case .hotspots: return "personalhotspot"
        case .settings: return "gearshape.fill"
        }
    }
}

@MainActor final class LabModel: ObservableObject {
    @Published var devices: [ContinuityDevice] = []
    @Published var nearbyPeers: [NearbyPeer] = []
    @Published var discoveryStatus = "Looking for Samsung devices…"
    @Published var status = "Sign in with Samsung, or import a Galaxy Connect connection."
    @Published var signingIn = false
    @Published var hasNativeSignIn = false
    @Published var accountEmail = ""
    private var started = false
    private var bluetoothDiagnostic: BluetoothDiscovery?
    @Published var profile: ContinuityProfile?
    @Published var pending: Data?
    @Published var code = ""
    @Published var busy = false
    @Published var connected = false
    @Published var hotspotBusy = false
    /// On by default and remembered, like Samsung's own clipboard sharing.
    @Published var automaticClipboard = UserDefaults.standard.object(forKey: "automaticClipboard") as? Bool ?? true {
        didSet {
            guard !AppVersion.isRenderingDemo, !AppVersion.isWindowSelfTest else { return }
            UserDefaults.standard.set(automaticClipboard, forKey: "automaticClipboard")
            lastChange = NSPasteboard.general.changeCount
            for link in [session].compactMap({ $0 }) + clipboardSessions { link.clipboardEnabled = automaticClipboard }
            lanPresence?.clipboardEnabled = automaticClipboard
            updateClipboardPool()
        }
    }
    /// Smart Galaxy Book-style automatic phone connection on launch, wake, and proximity.
    @Published var autoConnect = UserDefaults.standard.object(forKey: "continuity.autoConnect") as? Bool ?? true {
        didSet {
            guard !AppVersion.isRenderingDemo else { return }
            UserDefaults.standard.set(autoConnect, forKey: "continuity.autoConnect")
            if autoConnect && !userPaused && !connected && !busy {
                triggerSmartConnect(reason: "auto-connect enabled")
            } else if !autoConnect { cancelReconnectTimer() }
            updateClipboardPool()
        }
    }
    @Published var clipboardNotifications = UserDefaults.standard.object(forKey: "continuity.clipboardNotifications") as? Bool ?? false {
        didSet { UserDefaults.standard.set(clipboardNotifications, forKey: "continuity.clipboardNotifications") }
    }
    @Published var launchAtLogin = false
    @Published var userPaused = false
    @Published var reconnectAttempt = 0
    @Published var reconnectSecondsRemaining = 0
    @Published var receivedText = ""
    @Published var receivedImage: NSImage?
    @Published var receivedImageBytes = 0
    @Published var lastClipboardDirection = ""
    @Published var lastClipboardDate: Date?
    @Published var selectedTarget = ""
    let nearbyClipboard = NearbyClipboardPool()
    @Published var clipboardPeerNames: [String] = []
    var clipboardSessions: [ClipboardSession] { [session].compactMap { $0 }.filter { connected && $0.peerAddress != nil } + nearbyClipboard.sessions + (lanPresence?.sessions ?? []) }
    var hasClipboardLinks: Bool { !clipboardSessions.isEmpty }
    func clipboardSession(for address: String) -> ClipboardSession? {
        guard let bytes = try? ContinuityProfile.addressBytes(address) else { return nil }
        return clipboardSessions.first { (try? ContinuityProfile.addressBytes($0.peerAddress ?? "")) == bytes }
    }
    var session: ClipboardSession?
    var sessionTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var diagnosticFeature: FeatureSession?
    private var startupTask: Task<Void, Never>?
    var clipboardTimer: Timer?
    /// Galaxy PCs (Galaxy Book) reached over the local network, alongside the phone.
    var lanPresence: LANPresence?
    @Published var lanPeers: [String] = []
    private var lanTimer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var wakeObserver: NSObjectProtocol?
    var lastChange = NSPasteboard.general.changeCount
    var joiningHotspot = false
    var hotspotJoiner = HotspotJoiner()
    /// On-demand hotspot answers: cached 20 s, invalidated on wake/disconnect.
    let hotspotCenter = HotspotCenter()
    /// Devices that answered "no hotspot" are excluded from new queries.
    let hotspotCapability = HotspotCapabilityMemory()
    let wifiMenu = WiFiMenuHotspot()
    private var statusQueries: [String: Task<Void, Never>] = [:]
    private var statusQueryIDs: [String: UUID] = [:]
    private var hotspotLinkedAddresses = Set<String>()
    private var statusRetryAfter: [String: Date] = [:]
    func refreshHotspotInformation() {
        for link in clipboardSessions { refreshHotspotInformation(link) }
    }
    private func refreshHotspotInformation(_ link: ClipboardSession) {
        guard let address = link.peerAddress, statusQueries[address] == nil,
              hotspotCenter.information(address: address) == nil,
              statusRetryAfter[address, default: .distantPast] <= Date() else { return }
        statusRetryAfter[address] = Date().addingTimeInterval(300)
        let id = UUID(); statusQueryIDs[address] = id
        statusQueries[address] = Task { [weak self, weak link] in
            guard let self, let link else { return }
            defer { if self.statusQueryIDs[address] == id { self.statusQueries[address] = nil; self.statusQueryIDs[address] = nil } }
            do {
                let info = try await link.requestHotspotInformation()
                guard self.statusQueryIDs[address] == id, self.clipboardSession(for: address) === link else { return }
                self.hotspotCenter.storeInformation(address: address, value: info)
                self.trace("Samsung status received: battery=\(info.batteryPercent.map(String.init) ?? "unknown")%.")
                self.objectWillChange.send()
            } catch { if !Task.isCancelled { self.trace("The device did not answer the non-activating hotspot status query; retry is delayed.") } }
        }
    }
    func retryHotspotInformation(for address: String) {
        statusQueryIDs[address] = nil
        statusQueries.removeValue(forKey: address)?.cancel()
        statusRetryAfter[address] = nil
        hotspotCapability.markAvailable(address)
        hotspotCenter.invalidate(address: address)
        if let link = clipboardSession(for: address) { refreshHotspotInformation(link) }
    }
    var homePeer: ContinuityProfile.Peer? {
        guard let peers = profile?.peers else { return nil }
        return GalaxyPeerPreference.home(peers: peers, connected: clipboardSessions.compactMap(\.peerAddress), nearby: nearbyPeers.filter(\.nearby).map(\.address), selected: selectedTarget)
    }
    var homeConnected: Bool { homePeer.flatMap { clipboardSession(for: $0.address) } != nil }

    let discovery = ContinuityDiscovery()
    private static let backoffSchedule = [2, 5, 10, 20, 45, 60]

    var targetPeer: ContinuityProfile.Peer? {
        guard let profile else { return nil }
        return profile.peers.first(where: { $0.address == selectedTarget })
            ?? profile.peers.first(where: { $0.deviceType?.lowercased() == "phone" })
            ?? profile.peers.first
    }

    var targetDisplayName: String {
        targetPeer?.name ?? "Galaxy Phone"
    }

    var targetModelName: String? {
        targetPeer?.model
    }

    var visualState: ConnectionVisualState {
        guard profile != nil else { return .signedOut }
        if userPaused { return .paused }
        if connected { return .connected(targetDisplayName) }
        if busy { return .connecting(targetDisplayName) }
        if reconnectSecondsRemaining > 0 {
            return .reconnecting(attempt: max(1, reconnectAttempt), secondsRemaining: reconnectSecondsRemaining)
        }
        return .searching
    }

    func note(_ value: String) {
        status = value
        trace(value)
    }

    func trace(_ value: String) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--diagnostic-output"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            if let handle = try? FileHandle(forWritingTo: url) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data((value + "\n").utf8)) }
            else { try? (value + "\n").write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    func start() {
        guard !started else { return }; started = true
        launchAtLogin = SMAppService.mainApp.status == .enabled
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--ble-capture"), index + 1 < arguments.count {
            // Explicit diagnostic mode: a bounded passive snapshot, separate from normal logging.
            let capture = BluetoothDiscovery(); bluetoothDiagnostic = capture
            let output = URL(fileURLWithPath: arguments[index + 1])
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                capture.stop()
                if let data = try? JSONSerialization.data(withJSONObject: Array(capture.samsungFrames.prefix(128))) {
                    try? data.write(to: output, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
                }
                self?.bluetoothDiagnostic = nil
            }
        }
        hotspotJoiner.progress = { [weak self] in self?.note($0) }
        discovery.changed = { [weak self] devices in
            guard let self else { return }; self.devices = devices
            var foundPC = false
            for device in devices {
                guard let address = device.address, let port = UInt16(exactly: device.port),
                      self.profile?.peers.contains(where: { $0.address == address && $0.deviceType?.lowercased() == "pc" }) == true else { continue }
                LANPresence.remember(host: device.host, port: port, peerAddress: address)
                foundPC = true
            }
            if foundPC { self.lanPresence?.connectPCs() }
        }
        discovery.nearbyChanged = { [weak self] peers in
            guard let self else { return }
            self.nearbyPeers = peers
            self.evaluateProximityAutoConnect(peers)
            self.updateClipboardPool()
        }
        discovery.bluetoothStatus = { [weak self] in self?.discoveryStatus = $0 }
        discovery.failed = { [weak self] in self?.status = $0 }

        nearbyClipboard.opened = { [weak self] link, name in
            guard let self else { return }
            link.clipboardEnabled = self.automaticClipboard
            link.trace = { [weak self] in self?.trace($0) }
            self.receiveClipboard(from: link, name: name)
        }
        nearbyClipboard.changed = { [weak self] in self?.updateNearbyConnections(); self?.refreshHotspotInformation() }
        nearbyClipboard.status = { [weak self] in self?.trace($0) }
        wifiMenu.center = hotspotCenter
        wifiMenu.capability = hotspotCapability
        wifiMenu.note = { [weak self] in self?.note($0) }
        wifiMenu.liveSession = { [weak self] in
            guard let self else { return nil }
            let peers = (self.profile?.peers ?? []).sorted { ($0.deviceType == "phone" ? 0 : 1) < ($1.deviceType == "phone" ? 0 : 1) }
            for peer in peers where !self.hotspotCapability.unavailable(peer.address) {
                if let session = self.clipboardSession(for: peer.address) {
                    // Availability is checked by the publisher. The lookup must also
                    // work with an expired cache so menu opening can refresh it.
                    return (session, peer.address, peer.name)
                }
            }
            return nil
        }
        wifiMenu.start()
        installSystemObservers()

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--bootstrap-fifo"), i + 1 < args.count {
            do {
                var info = stat(); let path = args[i + 1]
                guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFIFO, let handle = FileHandle(forReadingAtPath: path) else { throw ContinuityError.message("Bootstrap input is not a named pipe.") }
                defer { try? handle.close() }
                let value = try JSONDecoder().decode(ContinuityProfile.self, from: handle.readDataToEndOfFile())
                try ProfileStore.save(value); note("Profile imported into \(ContinuityLoginStorage.description).")
            } catch { note(error.localizedDescription) }
        }
        discovery.start()
        // Keychain can wait for a user approval after an app update. Keep the
        // window and independent Buds controls responsive during that wait.
        let signInService = ContinuitySignIn.shared
        startupTask?.cancel()
        startupTask = Task {
            if args.contains("--import-keychain-login") {
                do { try await Task.detached { try ContinuityLoginStorage.importKeychainForTesting() }.value }
                catch { note(error.localizedDescription) }
            }
            let stored = await Task.detached { try? ProfileStore.load() }.value
            guard !Task.isCancelled else { return }
            if let value = stored, profile == nil {
                profile = value; discovery.profile = value; status = "Scanning for your Galaxy devices…"
                selectedTarget = selectBestTarget(for: value)
                // Test hook: --peer <address> picks another registered device, such as a tablet.
                if let i = args.firstIndex(of: "--peer"), i + 1 < args.count, value.peers.contains(where: { $0.address == args[i + 1] }) { selectedTarget = args[i + 1] }
                discovery.stop(); discovery.start()
                startLANPresence(value)
            }
            let savedSignIn = await Task.detached { (try? signInService.hasStoredSignIn()) ?? false }.value
            guard !Task.isCancelled else { return }
            hasNativeSignIn = savedSignIn
            accountEmail = (try? signInService.signedInAccountLabel()) ?? ""
            if args.contains("--start-sign-in") { signIn() }
            if args.contains("--refresh-sign-in") { signIn(refresh: true) }
            if args.contains("--start-probe") || (autoConnect && profile != nil && !userPaused) {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                connectBluetooth()
            }
        }
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.automaticClipboard, self.hasClipboardLinks, self.lastChange != NSPasteboard.general.changeCount else { return }
                self.lastChange = NSPasteboard.general.changeCount; self.sendClipboard()
            }
        }
    }

    private func selectBestTarget(for value: ContinuityProfile) -> String {
        if let saved = UserDefaults.standard.string(forKey: "continuity.preferredPeerAddress"),
           value.peers.contains(where: { $0.address == saved }) {
            return saved
        }
        if let preferred = value.preferredPeerAddress,
           value.peers.contains(where: { $0.address == preferred }) {
            return preferred
        }
        return value.peers.first(where: { $0.deviceType?.lowercased() == "phone" })?.address
            ?? value.peers.first?.address
            ?? ""
    }

    private func installSystemObservers() {
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.trace("Mac woke from sleep; refreshing Galaxy continuity links.")
                    self.statusQueryIDs.removeAll()
                    for task in self.statusQueries.values { task.cancel() }; self.statusQueries.removeAll()
                    self.statusRetryAfter.removeAll()
                    self.wifiMenu.invalidateCache()
                    self.refreshHotspotInformation()
                    self.reconnectAttempt = 0
                    self.lanPresence?.connectPCs()
                    if self.autoConnect, !self.userPaused, !self.connected, !self.busy {
                        self.scheduleReconnect(immediate: true)
                    }
                }
            }
        }
        if pathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                guard path.status == .satisfied else { return }
                Task { @MainActor in
                    guard let self else { return }
                    self.lanPresence?.connectPCs()
                }
            }
            monitor.start(queue: DispatchQueue(label: "continuity.network.monitor"))
            pathMonitor = monitor
        }
    }

    func updateClipboardPool() {
        guard started else { return }
        nearbyClipboard.update(profile: profile, peers: nearbyPeers,
            excluding: selectedTarget.isEmpty ? [] : [selectedTarget],
            enabled: autoConnect && !userPaused && !signingIn, sharing: automaticClipboard)
    }

    private func evaluateProximityAutoConnect(_ peers: [NearbyPeer]) {
        guard autoConnect, !userPaused, !connected, !busy, !signingIn, profile != nil else { return }
        if let target = peers.first(where: { $0.address.caseInsensitiveCompare(selectedTarget) == .orderedSame }),
           target.bluetoothConnectable || target.bluetoothNearby {
            cancelReconnectTimer()
            reconnectAttempt = 0
            connectBluetooth()
        }
    }

    func triggerSmartConnect(reason: String) {
        guard profile != nil, !busy, !connected, !signingIn else { return }
        userPaused = false
        cancelReconnectTimer()
        reconnectAttempt = 0
        connectBluetooth()
    }

    func pauseConnection() {
        userPaused = true
        cancelReconnectTimer()
        disconnect(); nearbyClipboard.stop(); updateNearbyConnections()
        note("Automatic connection paused. Click Resume whenever you're ready.")
    }

    func resumeConnection() {
        userPaused = false
        reconnectAttempt = 0
        cancelReconnectTimer()
        connectBluetooth()
    }

    func selectPeerAndConnect(_ address: String) {
        selectedTarget = address
        UserDefaults.standard.set(address, forKey: "continuity.preferredPeerAddress")
        userPaused = false
        reconnectAttempt = 0
        cancelReconnectTimer()
        if connected || busy {
            disconnect()
        }
        connectBluetooth()
    }

    private func cancelReconnectTimer() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectSecondsRemaining = 0
    }

    private func scheduleReconnect(immediate: Bool = false) {
        guard autoConnect, !userPaused, profile != nil, !signingIn else { return }
        cancelReconnectTimer()
        if immediate {
            reconnectTask = Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled, !connected, !busy, !userPaused else { return }
                connectBluetooth()
            }
            return
        }
        let index = min(reconnectAttempt, Self.backoffSchedule.count - 1)
        let delay = Self.backoffSchedule[index]
        reconnectAttempt += 1
        reconnectSecondsRemaining = delay
        reconnectTask = Task {
            while reconnectSecondsRemaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, !connected, !busy, !userPaused else {
                    reconnectSecondsRemaining = 0
                    return
                }
                reconnectSecondsRemaining -= 1
            }
            guard !Task.isCancelled, !connected, !busy, !userPaused else { return }
            connectBluetooth()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            note("Launch at login could not be updated: \(error.localizedDescription)")
        }
    }

    func connectBluetooth() {
        guard var profile, !busy, !connected, !signingIn else { return }
        if !CommandLine.arguments.contains("--peer"),
           let nearby = nearbyPeers.first(where: { $0.bluetoothConnectable && ["phone", "tablet", "tab"].contains($0.deviceType?.lowercased() ?? "") && !nearbyClipboard.connectedAddresses.contains($0.id) }),
           !nearbyPeers.contains(where: { $0.address == selectedTarget && $0.bluetoothConnectable }) { selectedTarget = nearby.address }
        updateClipboardPool()
        cancelReconnectTimer()
        do {
            if !selectedTarget.isEmpty {
                profile.preferredPeerAddress = selectedTarget
                // Automatic fallback is temporary; explicit selection is saved by selectPeerAndConnect.
            }
            let transport = try BLEMCFTransport(profile: profile)
            transport.status = { [weak self] in self?.note($0) }
            let session = ClipboardSession(connection: transport, profile: profile)
            begin(session)
        } catch {
            note(error.localizedDescription)
            scheduleReconnect()
        }
    }

    func signIn(refresh: Bool = false) {
        guard !signingIn else { return }; startupTask?.cancel(); pauseConnection(); userPaused = false; signingIn = true
        Task {
            defer { signingIn = false; hasNativeSignIn = (try? ContinuitySignIn.shared.hasStoredSignIn()) ?? false; accountEmail = (try? ContinuitySignIn.shared.signedInAccountLabel()) ?? "" }
            do {
                var value: ContinuityProfile
                if refresh { value = try await ContinuitySignIn.shared.refresh(status: note, renewTokens: CommandLine.arguments.contains("--refresh-sign-in")) }
                else { value = try await ContinuitySignIn.shared.signIn(status: note) }
                if value.peers.contains(where: { $0.address == selectedTarget }) { value.preferredPeerAddress = selectedTarget }
                try ProfileStore.save(value); profile = value; discovery.profile = value
                selectedTarget = selectBestTarget(for: value)
                discovery.stop(); devices = []; discovery.start()
                startLANPresence(value)
                note("Native Mac enrollment completed. Connecting to your Galaxy device…")
                if autoConnect { connectBluetooth() }
            } catch { note(error.localizedDescription) }
        }
    }

    func signOut() {
        guard !signingIn else { return }; startupTask?.cancel(); cancelReconnectTimer(); disconnect(); nearbyClipboard.stop(); lanPresence?.stop(); lanPresence = nil
        do {
            try ContinuitySignIn.shared.signOut(); hasNativeSignIn = false; accountEmail = ""
            if profile?.borrowedIdentity == false { try ProfileStore.delete(); profile = nil; discovery.profile = nil; devices = [] }
            note("Samsung account sign-in removed from this app. A saved Windows import, if active, is retained.")
        } catch { note(error.localizedDescription) }
    }

    func importSavedLogin() {
        guard !busy, !signingIn else { return }
        startupTask?.cancel(); signingIn = true
        note("Copying this app's existing login. macOS may ask for Keychain access once.")
        Task {
            defer { signingIn = false }
            do {
                try await Task.detached { try ContinuityLoginStorage.importKeychainForTesting() }.value
                profile = try ProfileStore.load(); discovery.profile = profile
                hasNativeSignIn = try ContinuitySignIn.shared.hasStoredSignIn()
                accountEmail = (try? ContinuitySignIn.shared.signedInAccountLabel()) ?? ""
                if let profile { selectedTarget = selectBestTarget(for: profile); startLANPresence(profile) }
                discovery.stop(); devices = []; discovery.start()
                note("Login copied to private files. Future builds won't read Keychain.")
                if autoConnect { connectBluetooth() }
            } catch { note(error.localizedDescription) }
        }
    }

    func begin(_ session: ClipboardSession) {
        self.session = session; session.clipboardEnabled = automaticClipboard; busy = true
        session.status = { [weak self] in self?.note($0) }
        session.trace = { [weak self] in self?.trace($0) }
        session.eagerImages = !CommandLine.arguments.contains("--lazy-images")
        if CommandLine.arguments.contains("--capture-clip-archive") {
            // Development only: keep the phone's GET_CLIP archive in the app's private cache.
            session.captureClipArchives = true
            session.capturedClip = { [weak self] data in
                let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("local.galaxy-continuity-lab")
                let file = folder.appendingPathComponent("captured-clip-archive.zip")
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try data.write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    self?.trace("Captured phone clip archive (\(data.count) bytes).")
                } catch { self?.trace("Could not save clip archive: \(error.localizedDescription)") }
            }
        }
        receiveClipboard(from: session)
        session.hotspotReceived = { [weak self] value in
            guard let self else { return }
            let address = session.peerAddress ?? self.selectedTarget
            guard value.isSuccess == true else {
                self.joiningHotspot = false; self.hotspotBusy = false
                if !address.isEmpty { self.hotspotCapability.markUnavailable(address, reason: value.mhsfailed_reason) }
                self.note("The phone rejected Auto Hotspot (reason \(value.mhsfailed_reason ?? -1)). Automatic retries pause briefly; use Retry on the Auto Hotspot page after checking its setting.")
                return
            }
            if !address.isEmpty {
                self.hotspotCenter.store(address: address, credentials: value)
                self.hotspotCapability.markAvailable(address)
            }
            self.note("The phone enabled Auto Hotspot and returned its connection details.")
            if self.joiningHotspot {
                self.joiningHotspot = false
                Task {
                    defer { self.hotspotBusy = false }
                    do { try await self.hotspotJoiner.join(value); self.note("Connected the Mac to the phone hotspot.") } catch { self.note(error.localizedDescription) }
                }
            }
        }
        sessionTask = Task {
            defer {
                let shouldRetry = !Task.isCancelled && !userPaused && autoConnect && profile != nil
                session.stop()
                if self.session === session {
                    busy = false; connected = false
                    hotspotCenter.invalidate(address: session.peerAddress ?? selectedTarget)   // far away → re-ask next time
                    updateNearbyConnections()
                    if shouldRetry { scheduleReconnect() }
                }
            }
            do {
                // Only copies made after connecting are shared, not whatever was already on the clipboard.
                try await session.connect()
                session.clipboardEnabled = automaticClipboard
                lastChange = NSPasteboard.general.changeCount
                connected = true
                busy = false
                reconnectAttempt = 0
                reconnectSecondsRemaining = 0
                updateNearbyConnections()
                refreshHotspotInformation(session)
                if CommandLine.arguments.contains("--clipboard-feature-test"), let profile {
                    let feature = FeatureSession(appID: 10); diagnosticFeature = feature
                    feature.status = { self.trace("Command-path probe: " + $0) }
                    Task {
                        defer { feature.disconnect(); diagnosticFeature = nil }
                        do {
                            try await feature.connect(profile: profile, sharing: session)
                            trace("Command-path probe: authenticated feature socket, peer IPv4 \(feature.peerIP ?? "unknown")")
                            try await Task.sleep(nanoseconds: 3_000_000_000)
                        } catch { trace("Command-path probe: " + error.localizedDescription) }
                    }
                }
                if CommandLine.arguments.contains("--clipboard-test") {
                    try await session.publish("Galaxy Continuity test: café 日本語 🚀 — Mac to phone")
                    note("TEST: Announced the controlled Unicode clipboard sample.")
                }
                if CommandLine.arguments.contains("--send-clipboard-on-connect") { self.sendClipboard() }
                if CommandLine.arguments.contains("--hotspot-join-test") { joiningHotspot = true }
                if CommandLine.arguments.contains("--hotspot-test") || joiningHotspot { try await session.requestHotspot() }
                try await session.run()
            }
            catch {
                note(error.localizedDescription)
            }
        }
    }

    func receiveClipboard(from session: ClipboardSession, name: String? = nil) {
        session.clipboardEnabled = automaticClipboard
        let peerName = name ?? targetDisplayName
        session.received = { [weak self, weak session] clip in
            guard let self, self.automaticClipboard, session?.clipboardEnabled == true else { return }
            self.receivedText = clip.text
            self.receivedImage = nil
            self.receivedImageBytes = 0
            self.lastClipboardDirection = "From \(peerName)"
            self.lastClipboardDate = Date()
            let board = NSPasteboard.general; board.clearContents(); board.setString(clip.text, forType: .string)
            if let html = clip.html { board.setString(html, forType: .html) }
            self.lastChange = board.changeCount; self.note("Received phone text and placed it on the Mac clipboard.")
            self.notifyClipboardArrival(summary: "Text copied from \(peerName)")
        }
        session.receivedImage = { [weak self, weak session] data in
            guard let self, self.automaticClipboard, session?.clipboardEnabled == true, let image = NSImage(data: data) else { return }
            self.receivedImage = image
            self.receivedImageBytes = data.count
            self.lastClipboardDirection = "From \(peerName)"
            self.lastClipboardDate = Date()
            // Keep the phone's original JPEG/HEIC/PNG bytes, plus TIFF for apps that need it.
            let item = NSPasteboardItem()
            if let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) {
                item.setData(data, forType: NSPasteboard.PasteboardType(type as String))
            }
            if let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
            let board = NSPasteboard.general; board.clearContents(); board.writeObjects([item])
            self.lastChange = board.changeCount; self.note("Received phone image and placed it on the Mac clipboard.")
            self.notifyClipboardArrival(summary: "Image (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))) copied from \(peerName)")
        }
    }

    private func notifyClipboardArrival(summary: String) {
        guard clipboardNotifications, Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Galaxy Continuity"
            content.body = summary
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }

    func startLANPresence(_ profile: ContinuityProfile) {
        guard !CommandLine.arguments.contains("--no-lan-pcs") else { return }
        lanPresence?.stop(); lanTimer?.invalidate(); lanTimer = nil
        let presence = LANPresence(profile: profile)
        presence.clipboardEnabled = automaticClipboard
        presence.status = { [weak self] in self?.note($0) }
        presence.trace = { [weak self] in self?.trace($0) }
        presence.opened = { [weak self] session in
            session.status = { self?.note($0) }; session.trace = { self?.trace($0) }
            self?.receiveClipboard(from: session, name: "Galaxy Book")
        }
        presence.changed = { [weak self, weak presence] in
            let names = Set(presence?.connectedPeers ?? [])
            self?.lanPeers = profile.peers.filter { names.contains($0.address) }.map(\.name)
            self?.updateNearbyConnections()
        }
        do { try presence.start(); lanPresence = presence } catch { note("Galaxy PC sharing is unavailable: " + error.localizedDescription); return }
        // Dial PCs shortly after launch, then retry while none is connected.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { presence.connectPCs() }
        lanTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in Task { @MainActor in presence.connectPCs() } }
    }

    /// Sends one clipboard change to the phone and to every connected Galaxy PC.
    private func share(_ action: @escaping (ClipboardSession) async throws -> Void) {
        for target in clipboardSessions {
            Task { do { try await action(target) } catch { note(error.localizedDescription) } }
        }
    }

    func updateNearbyConnections() {
        let live = Set(clipboardSessions.compactMap(\.peerAddress))
        for address in hotspotLinkedAddresses.subtracting(live) {
            statusQueryIDs[address] = nil
            statusQueries.removeValue(forKey: address)?.cancel()
            statusRetryAfter[address] = nil
            hotspotCenter.invalidate(address: address)
        }
        hotspotLinkedAddresses = live
        var addresses = lanPresence?.connectedPeers ?? []
        if connected, let address = session?.peerAddress { addresses.append(address) }
        addresses += nearbyClipboard.sessions.compactMap(\.peerAddress)
        clipboardPeerNames = addresses.compactMap { address in profile?.peers.first(where: { (try? ContinuityProfile.addressBytes($0.address)) == (try? ContinuityProfile.addressBytes(address)) })?.name }
        discovery.setConnectedPeers(addresses)
    }

    func disconnect() {
        sessionTask?.cancel()
        session?.stop()
        session = nil
        connected = false
        busy = false
        updateNearbyConnections()
    }

    func sendClipboard() {
        guard automaticClipboard, hasClipboardLinks else { return }
        let board = NSPasteboard.general
        // A single image file copied in Finder sends the image, not its name.
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], urls.count == 1,
           let type = UTType(filenameExtension: urls[0].pathExtension), type.conforms(to: .image),
           let size = try? urls[0].resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 * 1024 * 1024,
           let data = try? Data(contentsOf: urls[0]) {
            let name = type.conforms(to: .jpeg) ? "image.jpg" : type.conforms(to: .heic) ? "image.heic" : type.conforms(to: .png) ? "image.png" : nil
            guard let bytes = name != nil ? data : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { note("This image file cannot be sent."); return }
            lastClipboardDirection = "Sent from Mac"
            lastClipboardDate = Date()
            share { try await $0.publishImage(bytes, fileName: name ?? "image.png") }; return
        }
        // Send a photo's original bytes when available; TIFF is re-encoded as PNG below.
        for (type, name) in [(NSPasteboard.PasteboardType("public.jpeg"), "image.jpg"), (NSPasteboard.PasteboardType("public.heic"), "image.heic"), (.png, "image.png")] {
            guard let data = board.data(forType: type) else { continue }
            lastClipboardDirection = "Sent from Mac"
            lastClipboardDate = Date()
            share { try await $0.publishImage(data, fileName: name) }; return
        }
        if let tiff = board.data(forType: .tiff) {
            guard tiff.count <= 32 * 1024 * 1024, let bitmap = NSBitmapImageRep(data: tiff),
                  bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
                  bitmap.pixelsWide <= 16384, bitmap.pixelsHigh <= 16384,
                  bitmap.pixelsWide <= 40_000_000 / bitmap.pixelsHigh,
                  let png = bitmap.representation(using: .png, properties: [:]) else { note("Clipboard image is too large or invalid."); return }
            lastClipboardDirection = "Sent from Mac"
            lastClipboardDate = Date()
            share { try await $0.publishImage(png) }; return
        }
        guard let text = board.string(forType: .string) else { note("Copy text or an image on the Mac first."); return }
        let html = board.string(forType: .html)
        lastClipboardDirection = "Sent from Mac"
        lastClipboardDate = Date()
        share { try await $0.publish(text, html: html) }
    }

    func hotspot() {
        guard let session, connected, !hotspotBusy else { return }; joiningHotspot = true; hotspotBusy = true
        Task { do { try await session.requestHotspot() } catch { joiningHotspot = false; hotspotBusy = false; note(error.localizedDescription) } }
    }

    func unlock() {
        guard let pending else { return }
        do {
            let value = try ProfileStore.decrypt(pending, code: code.trimmingCharacters(in: .whitespacesAndNewlines))
            startupTask?.cancel()
            try ProfileStore.save(value); profile = value; discovery.profile = value
            selectedTarget = selectBestTarget(for: value)
            self.pending = nil; code = ""; discovery.stop(); devices = []; discovery.start(); status = "Connected profile imported. Scanning…"
            startLANPresence(value)
            if autoConnect { connectBluetooth() }
        } catch { status = error.localizedDescription }
    }

    func probe(_ device: ContinuityDevice) {
        guard let profile, !busy, let port = UInt16(exactly: device.port) else { return }
        busy = true; status = "Verifying the Samsung account handshake…"
        Task {
            let transport = MCFTransport(host: device.host, port: port); defer { transport.cancel(); busy = false }
            do { _ = try await transport.authenticate(profile: profile); note("Authenticated with \(device.name).") }
            catch { status = error.localizedDescription }
        }
    }
}

struct LabView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: LabModel
    @ObservedObject var buds: BudsModel
    @ObservedObject var features: FeaturesModel
    @ObservedObject var hotspots: HotspotsModel
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @ObservedObject private var calls = CallingController.shared
    @State var selectedSection: SidebarSection = {
        let args = CommandLine.arguments
        if args.contains("--buds-probe") { return .buds }
        if args.contains("--feature-test") || args.contains("--multi-test") { return .multiControl }
        return .home
    }()
    @State private var importing = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(LinearGradient(colors: [OneUI.blue, OneUI.deepBlue], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 34, height: 34)
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(AppVersion.appName)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        Text(AppVersion.display)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                List(SidebarSection.allCases, selection: $selectedSection) { section in
                    Label { Text(section.rawValue) } icon: {
                        Image(systemName: section.symbol).foregroundStyle(selectedSection == section ? (scheme == .dark ? Color.white : OneUI.blue) : Color.secondary)
                    }
                        .font(.system(size: 13, weight: .medium))
                        .tag(section)
                }
                .listStyle(.sidebar)

                Spacer()

                SidebarStatusFooter(model: model, calls: calls, buds: buds)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            .navigationSplitViewColumnWidth(min: 205, ideal: 220, max: 250)
        } detail: {
            ZStack {
                OneUI.canvasBackground(scheme)
                    .ignoresSafeArea()

                switch selectedSection {
                case .home:
                    HomePageView(
                        model: model,
                        buds: buds,
                        features: features,
                        calls: calls,
                        selectedSection: $selectedSection
                    )
                case .clipboard:
                    ClipboardPageView(model: model)
                case .calls:
                    CallsPanel()
                case .buds:
                    BudsPanel(model: buds)
                case .nearby:
                    NearbyDevicesPage(model: model, features: features, section: $selectedSection)
                case .multiControl:
                    MultiControlPage(model: model, features: features)
                case .hotspots:
                    HotspotsPage(model: model, hotspots: hotspots)
                case .settings:
                    SettingsPageView(model: model, features: features, importing: $importing)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(MainWindowAttachment())
        .frame(minWidth: 900, minHeight: 640)
        .onAppear {
            guard !AppVersion.isRenderingDemo else { return }
            AppWindowPolicy.shared.createWindow = { openWindow(id: "main") }
            AppWindowPolicy.shared.selectSection = { selectedSection = $0 }
            if let pending = AppWindowPolicy.shared.takePendingSection() { selectedSection = pending }
            AppWindowPolicy.shared.displayedSection = selectedSection
        }
        .onChange(of: selectedSection) { AppWindowPolicy.shared.displayedSection = $0 }
        .onChange(of: model.connected) { isConnected in
            features.sharedCommand = isConnected ? model.session : nil
            features.sharedCommandPeerAddress = isConnected ? model.selectedTarget : nil
        }
        .onChange(of: model.profile != nil) { available in
            if available, CommandLine.arguments.contains("--feature-test"), let profile = model.profile {
                features.connectStorage(profile: profile, device: nil)
            }
            if available, CommandLine.arguments.contains("--multi-test"), let profile = model.profile {
                features.connectMulti(profile: profile, device: nil)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .json]) { result in
            do {
                let url = try result.get(); let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                model.pending = try Data(contentsOf: url)
            } catch { model.status = error.localizedDescription }
        }
        .sheet(isPresented: Binding(get: { model.pending != nil }, set: { if !$0 { model.pending = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Unlock Galaxy Connect Connection").font(.system(size: 18, weight: .bold, design: .rounded))
                SecureField("Connection unlock code", text: $model.code).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { model.pending = nil }
                    Spacer()
                    Button("Import") { model.unlock() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 420)
        }
    }
}

private struct SidebarStatusFooter: View {
    @ObservedObject var model: LabModel
    @ObservedObject var calls: CallingController
    @ObservedObject var buds: BudsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                Text(headline)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            Text(model.status)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var dotColor: Color {
        switch model.visualState {
        case .connected: return OneUI.green
        case .connecting, .reconnecting: return OneUI.amber
        case .searching: return OneUI.blue
        case .paused, .signedOut: return .secondary
        }
    }

    private var headline: String {
        switch model.visualState {
        case .connected(let name): return name
        case .connecting(let name): return "Connecting to \(name)…"
        case .reconnecting(_, let s): return "Retry in \(s)s…"
        case .searching: return "Searching nearby…"
        case .paused: return "Paused"
        case .signedOut: return "Not signed in"
        }
    }
}

struct HomePageView: View {
    @ObservedObject var model: LabModel
    @ObservedObject var buds: BudsModel
    @ObservedObject var features: FeaturesModel
    @ObservedObject var calls: CallingController
    @Binding var selectedSection: SidebarSection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                OneUIPageHeader("Galaxy Ecosystem", subtitle: "Connected experience across your Galaxy phone, tablet, Galaxy Book and Buds") {
                    OneUIStatusPill(statusText, tone: statusTone)
                }

                HeroDeviceCard(model: model, calls: calls, selectedSection: $selectedSection)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Quick Panel")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        OneUIQuickTile(
                            title: "Clipboard Sync",
                            subtitle: model.automaticClipboard ? "All nearby devices" : "Sync off",
                            symbol: "doc.on.clipboard.fill",
                            isOn: model.automaticClipboard
                        ) {
                            model.automaticClipboard.toggle()
                        }

                        OneUIQuickTile(
                            title: "Auto Hotspot",
                            subtitle: "Choose a nearby hotspot",
                            symbol: "personalhotspot",
                            isOn: model.hotspotBusy,
                            isBusy: model.hotspotBusy,
                            isDisabled: model.profile == nil
                        ) {
                            selectedSection = .hotspots
                        }

                        OneUIQuickTile(
                            title: "Phone Calls",
                            subtitle: calls.phase == .registered ? "Registered (CMC)" : (calls.phase == .stopped ? "Off · Tap to enable" : "Connecting…"),
                            symbol: "phone.fill",
                            isOn: calls.phase == .registered,
                            isBusy: calls.phase == .enrolling || calls.phase == .connecting
                        ) {
                            if calls.phase == .stopped {
                                calls.start()
                            } else {
                                selectedSection = .calls
                            }
                        }

                        OneUIQuickTile(
                            title: "Buds Auto Switch",
                            subtitle: buds.automaticSwitching ? "Watching Mac audio" : (buds.devices.isEmpty ? "No paired Buds" : "Tap to enable"),
                            symbol: "earbuds",
                            isOn: buds.automaticSwitching || buds.connected,
                            isBusy: buds.busy
                        ) {
                            if buds.selection.isEmpty {
                                selectedSection = .buds
                            } else {
                                buds.setAutomaticSwitching(!buds.automaticSwitching)
                            }
                        }

                        OneUIQuickTile(
                            title: "Storage Share",
                            subtitle: features.storage.mountURL != nil ? "Mounted in Finder" : "Browse phone files",
                            symbol: "externaldrive.fill.badge.wifi",
                            isOn: features.storage.mountURL != nil,
                            isBusy: features.busy
                        ) {
                            features.sharedCommand = model.connected ? model.session : nil
                            selectedSection = .nearby
                        }

                        OneUIQuickTile(
                            title: "Multi Control",
                            subtitle: features.multi.controlling ? "Controlling phone" : (features.multiConnected ? "Connected" : "Share mouse & keys"),
                            symbol: "rectangle.connected.to.line.below",
                            isOn: features.multiConnected || features.multi.controlling,
                            isBusy: features.busy
                        ) {
                            features.sharedCommand = model.connected ? model.session : nil
                            selectedSection = .multiControl
                        }
                    }
                }

                HStack(alignment: .top, spacing: 18) {
                    RecentClipboardCard(model: model, selectedSection: $selectedSection)
                    NearbyEcosystemCard(model: model)
                }
            }
            .padding(28)
        }
    }

    private var statusText: String {
        switch model.visualState {
        case .connected: return model.homeConnected ? "Connected · \(model.homePeer?.name ?? "Galaxy phone")" : "Galaxy connections active"
        case .connecting: return "Connecting…"
        case .reconnecting(_, let s): return "Reconnecting in \(s)s"
        case .searching: return "Searching Nearby"
        case .paused: return "Paused"
        case .signedOut: return "Sign In Required"
        }
    }

    private var statusTone: StatusTone {
        switch model.visualState {
        case .connected: return .connected
        case .connecting, .reconnecting: return .warning
        case .searching: return .active
        case .paused, .signedOut: return .neutral
        }
    }
}

private struct HeroDeviceCard: View {
    @ObservedObject var model: LabModel
    @ObservedObject var calls: CallingController
    @Binding var selectedSection: SidebarSection

    var body: some View {
        OneUICard(padding: 22) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 18) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: model.connected ? [OneUI.blue, OneUI.deepBlue] : [Color.primary.opacity(0.10), Color.primary.opacity(0.05)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 66, height: 66)
                        Image(systemName: model.homePeer?.deviceType?.lowercased() == "phone" ? "iphone.gen3" : "ipad")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(model.connected ? Color.white : Color.primary)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(model.profile == nil ? "Welcome to Galaxy Continuity" : (model.homePeer?.name ?? "Galaxy Phone"))
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                            if let modelCode = model.homePeer?.model, !modelCode.isEmpty {
                                Text(modelCode)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                            }
                        }
                        if let peer = model.homePeer, let battery = model.hotspotCenter.information(address: peer.address)?.batteryPercent {
                            Label("\(battery)%", systemImage: "battery.100").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(model.homeConnected ? "Authenticated clipboard session active with this device." : (model.connected ? "This phone is not connected. Other Galaxy device connections remain active." : subtitleText))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)

                        HStack(spacing: 8) {
                            OneUIStatusPill(
                                model.homeConnected ? "Bluetooth" : (model.autoConnect ? "Smart Auto-Connect" : "Manual Mode"),
                                tone: model.homeConnected ? .connected : .active,
                                symbol: "antenna.radiowaves.left.and.right"
                            )
                            if !model.lanPeers.isEmpty {
                                OneUIStatusPill(
                                    "LAN · " + model.lanPeers.joined(separator: ", "),
                                    tone: .connected,
                                    symbol: "laptopcomputer"
                                )
                            }
                            if calls.phase == .registered {
                                OneUIStatusPill("Calls Ready", tone: .connected, symbol: "phone.fill")
                            }
                        }
                        .padding(.top, 2)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 8) {
                        if model.profile == nil {
                            Button(model.signingIn ? "Signing In…" : "Sign In with Samsung") {
                                model.signIn()
                            }
                            .buttonStyle(OneUIPrimaryButtonStyle())
                            .disabled(model.signingIn)
                        } else if model.connected || model.busy {
                            Button("Pause Device Connections") {
                                model.pauseConnection()
                            }
                            .buttonStyle(OneUISecondaryButtonStyle())
                            .help("Disconnect nearby phones and tablets and pause their automatic reconnection. Clipboard Sync remains enabled for Galaxy PC network links; use its switch to stop all clipboard sharing.")
                        } else if model.userPaused {
                            Button("Resume Connection") {
                                model.resumeConnection()
                            }
                            .buttonStyle(OneUIPrimaryButtonStyle())
                        } else {
                            Button("Connect Now") {
                                model.triggerSmartConnect(reason: "manual button")
                            }
                            .buttonStyle(OneUIPrimaryButtonStyle())
                            .disabled(model.signingIn)
                        }


                    }
                }
            }
        }
    }

    private var subtitleText: String {
        switch model.visualState {
        case .signedOut:
            return "Sign in with your Samsung account to enroll this Mac and automatically link your Galaxy devices."
        case .connected:
            return "Authenticated session active. Text and images sync automatically across your clipboard."
        case .connecting(let name):
            return "Opening encrypted Samsung MCF channel to \(name)…"
        case .reconnecting(_, let seconds):
            return "Phone out of range or busy — retrying automatically in \(seconds)s (or immediately when detected nearby)."
        case .paused:
            return "Automatic connection is paused. Click Resume Connection when you want to reconnect."
        case .searching:
            return model.discoveryStatus
        }
    }
}

private struct RecentClipboardCard: View {
    @ObservedObject var model: LabModel
    @Binding var selectedSection: SidebarSection

    var body: some View {
        OneUICard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Clipboard Continuity", systemImage: "doc.on.clipboard")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Spacer()
                    if !model.lastClipboardDirection.isEmpty {
                        OneUIStatusPill(model.lastClipboardDirection, tone: .active)
                    }
                }

                if let image = model.receivedImage {
                    HStack(spacing: 14) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Photo Received from Phone")
                                .font(.system(size: 14, weight: .semibold))
                            Text(ByteCountFormatter.string(fromByteCount: Int64(model.receivedImageBytes), countStyle: .file) + " · Ready to paste (⌘V)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(model.receivedText.isEmpty ? "Copy text or an image on your Galaxy phone or Mac — it syncs automatically." : model.receivedText)
                        .font(.system(size: 13))
                        .foregroundStyle(model.receivedText.isEmpty ? .secondary : .primary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                }

                HStack(spacing: 10) {
                    Button("Send Mac Clipboard") {
                        model.sendClipboard()
                    }
                    .buttonStyle(OneUIPrimaryButtonStyle())
                    .disabled(!model.automaticClipboard || !model.hasClipboardLinks)

                    Button("Open Clipboard View") {
                        selectedSection = .clipboard
                    }
                    .buttonStyle(OneUISecondaryButtonStyle())
                }
            }
        }
    }
}

private struct NearbyEcosystemCard: View {
    @ObservedObject var model: LabModel

    var body: some View {
        OneUICard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Nearby Devices", systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Spacer()
                    Text("\(model.nearbyPeers.filter(\.nearby).count)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }

                if model.nearbyPeers.filter(\.nearby).isEmpty {
                    Text("No nearby device detected. Turn on Bluetooth on your Galaxy devices.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.nearbyPeers.filter(\.nearby).prefix(4)) { peer in
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(peer.connected ? OneUI.green.opacity(0.16) : (peer.nearby ? OneUI.blue.opacity(0.14) : Color.primary.opacity(0.06)))
                                        .frame(width: 34, height: 34)
                                    Image(systemName: peer.symbol)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(peer.connected ? OneUI.green : (peer.nearby ? OneUI.blue : .secondary))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.name)
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(peer.connected ? "Connected" : peer.bluetoothNearby ? "Nearby over Bluetooth" : "Found on local network")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if peer.connected {
                                    OneUIStatusPill("Active", tone: .connected)
                                } else if let endpoint = peer.network {
                                    Button("Verify") { model.probe(endpoint) }
                                        .buttonStyle(OneUISecondaryButtonStyle())
                                        .disabled(model.busy || model.signingIn)
                                } else if peer.nearby {
                                    Button("Connect") {
                                        model.selectPeerAndConnect(peer.address)
                                    }
                                    .buttonStyle(OneUISecondaryButtonStyle())
                                    .disabled(model.signingIn)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }
}

struct ClipboardPageView: View {
    @ObservedObject var model: LabModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                OneUIPageHeader("Clipboard Continuity", subtitle: "Copy text, rich HTML or photos between your nearby Galaxy devices and Mac") {
                    OneUIStatusPill(model.automaticClipboard ? "Sync Enabled" : "Sync Off", tone: model.automaticClipboard ? .connected : .neutral)
                }

                OneUICard {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Sync Text & Images Automatically")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                            Text("Automatically connects nearby phones and tablets on your Samsung account, plus Galaxy Books on the local network. Turning this off stops sending and receiving clipboard items.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $model.automaticClipboard)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }

                OneUICard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Last Received Clipboard Item")
                                .font(.system(size: 15, weight: .semibold))
                            Spacer()
                            Button("Send Current Mac Clipboard") {
                                model.sendClipboard()
                            }
                            .buttonStyle(OneUIPrimaryButtonStyle())
                            .disabled(!model.automaticClipboard || !model.hasClipboardLinks)
                            .help("Send the current Mac clipboard to connected devices. The preview shows the last item received, which may be different. Clipboard Sync and a device connection are required.")
                        }

                        if let image = model.receivedImage {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 280)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        } else {
                            Text(model.receivedText.isEmpty ? "No clipboard item received in this session yet." : model.receivedText)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
                                .padding(14)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(Color.primary.opacity(0.04))
                                )
                        }

                        if !model.lanPeers.isEmpty {
                            Label("Also syncing over Wi-Fi with Galaxy PC: " + model.lanPeers.joined(separator: ", "), systemImage: "laptopcomputer.and.iphone")
                                .font(.system(size: 12))
                                .foregroundStyle(OneUI.blue)
                        }
                    }
                }
            }
            .padding(28)
        }
    }
}

struct SettingsPageView: View {
    @ObservedObject var model: LabModel
    @ObservedObject var features: FeaturesModel
    @Binding var importing: Bool
    @State private var showAdvanced = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                OneUIPageHeader("Settings", subtitle: "Samsung account enrollment, smart connection preferences and diagnostics") {
                    OneUIStatusPill(AppVersion.full, tone: .active)
                }

                OneUICard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(LinearGradient(colors: [OneUI.blue, OneUI.deepBlue], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 48, height: 48)
                                Image(systemName: "person.crop.circle.badge.checkmark")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Samsung Account")
                                    .font(.system(size: 17, weight: .bold, design: .rounded))
                                if !model.accountEmail.isEmpty {
                                    Text(model.accountEmail).font(.callout).textSelection(.enabled)
                                }
                                Text(model.profile == nil ? "Not enrolled yet — sign in with your Samsung account." : (model.profile?.borrowedIdentity == true ? "Signed in using an imported connection." : "Signed in on this Mac."))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            OneUIStatusPill(model.profile != nil ? "Enrolled" : "Signed Out", tone: model.profile != nil ? .connected : .neutral)
                        }

                        Divider()

                        HStack(spacing: 10) {
                            Button(model.signingIn ? "Signing In…" : (model.hasNativeSignIn ? "Sign In Again" : "Sign In with Samsung")) {
                                model.signIn()
                            }
                            .buttonStyle(OneUIPrimaryButtonStyle())
                            .disabled(model.signingIn)

                            if model.hasNativeSignIn {
                                Button("Refresh Mac Connection") {
                                    model.signIn(refresh: true)
                                }
                                .buttonStyle(OneUISecondaryButtonStyle())
                                .disabled(model.signingIn)

                                Button("Sign Out") {
                                    model.signOut()
                                }
                                .buttonStyle(OneUISecondaryButtonStyle())
                                .disabled(model.signingIn)
                            }
                        }
                    }
                }

                OneUICard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Smart Connection & Startup")
                            .font(.system(size: 16, weight: .bold, design: .rounded))

                        Toggle("Connect nearby Galaxy devices automatically (launch, wake & proximity)", isOn: $model.autoConnect)
                            .toggleStyle(OneUIAlignedSwitchStyle())

                        Toggle("Show a macOS banner when a Galaxy clipboard item arrives", isOn: $model.clipboardNotifications)
                            .toggleStyle(OneUIAlignedSwitchStyle())

                        Toggle("Open Galaxy Continuity at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                            .toggleStyle(OneUIAlignedSwitchStyle())

                        Divider()
                        Text("Clipboard sharing automatically joins nearby devices on your Samsung account. No device selection is needed.")
                            .font(.caption).foregroundStyle(.secondary)
                        if !model.clipboardPeerNames.isEmpty {
                            Text("Clipboard connected: " + model.clipboardPeerNames.joined(separator: ", "))
                                .font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                UpdatesCard(canInstall: !features.multi.controlling && !features.busy && features.storage.mountURL == nil)

                OneUICard {
                    DisclosureGroup("Advanced & Migration Tools", isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Credentials are stored in \(ContinuityLoginStorage.description).")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)

                            HStack(spacing: 10) {
                                Button("Import Windows Connection File…") {
                                    importing = true
                                }
                                .buttonStyle(OneUISecondaryButtonStyle())

                                if !ContinuityLoginStorage.usesKeychain && !model.hasNativeSignIn {
                                    Button("Import Existing Keychain Login Once") {
                                        model.importSavedLogin()
                                    }
                                    .buttonStyle(OneUISecondaryButtonStyle())
                                    .disabled(model.signingIn || model.busy)
                                }
                            }

                            Divider()

                            Text("Status trace: \(model.status)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .padding(.top, 10)
                    }
                    .font(.system(size: 14, weight: .semibold))
                }
            }
            .padding(28)
        }
    }
}

private struct SignInPromptCard: View {
    @ObservedObject var model: LabModel
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(OneUI.blue)
            Text("Sign in with your Samsung Account first")
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text("Storage Share and Multi Control use your authenticated Samsung Continuity profile.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button("Sign In with Samsung") { model.signIn() }
                .buttonStyle(OneUIPrimaryButtonStyle())
        }
        .padding(40)
    }
}

struct MenuBarExtraView: View {
    @ObservedObject var model: LabModel
    @ObservedObject var buds: BudsModel
    @ObservedObject var calls: CallingController
    @ObservedObject var hotspots: HotspotsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(AppVersion.appName) · \(AppVersion.display)")
                .font(.headline)
            Text(model.connected ? "Connected to \(model.targetDisplayName)" : (model.userPaused ? "Connection Paused" : model.status))
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Button("Send Mac Clipboard to Phone") {
                model.sendClipboard()
            }
            .disabled(!model.automaticClipboard || !model.hasClipboardLinks)

            Toggle("Auto-Sync Clipboard", isOn: $model.automaticClipboard)

            Menu("Auto Hotspot") {
                ForEach(model.nearbyPeers.filter { $0.nearby && $0.deviceType?.lowercased() != "pc" }) { peer in
                    Button(peer.name) {
                        if let profile = model.profile {
                            hotspots.join(profile: profile, peer: peer, existing: model.clipboardSession(for: peer.address))
                        }
                    }.disabled(hotspots.busy)
                }
                Button("Show Hotspots…") { AppWindowPolicy.shared.show(.hotspots) }
            }

            if !buds.selection.isEmpty {
                Button("Take Galaxy Buds Audio on Mac") {
                    buds.takeAudio()
                }
            }

            Divider()

            if model.connected || model.busy {
                Button("Pause Automatic Connection") {
                    model.pauseConnection()
                }
            } else {
                Button("Connect Now") {
                    model.resumeConnection()
                }
                .disabled(model.profile == nil)
            }

            Button("Show Galaxy Continuity Window") {
                AppWindowPolicy.shared.show()
            }

            Divider()

            Button("Quit Galaxy Continuity") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

@main struct LabApp: App {
    @NSApplicationDelegateAdaptor(ContinuityAppDelegate.self) private var appDelegate
    @StateObject private var model = LabModel()
    @StateObject private var buds = BudsModel()
    @StateObject private var features = FeaturesModel()
    @StateObject private var hotspots = HotspotsModel()

    init() {
        if !AppVersion.isRenderingDemo && !AppVersion.isWindowSelfTest { try? SMBStorageRecovery.restore() }
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--render-screenshots"), idx + 1 < args.count {
            let outputDir = args[idx + 1]
            Task { @MainActor in
                ScreenshotRenderer.renderAll(to: outputDir)
                exit(0)
            }
            return
        }
        if !AppVersion.isWindowSelfTest { Task { @MainActor in CallingPresence.start() } }
    }

    var body: some Scene {
        WindowGroup(AppVersion.appName, id: "main") {
            LabView(model: model, buds: buds, features: features, hotspots: hotspots)
                .task {
                    if AppVersion.isRenderingDemo { return }
                    if AppVersion.isWindowSelfTest { WindowLifecycleTest.start(); return }
                    model.start()
                    buds.trace = { model.trace($0) }
                    buds.start()
                    features.trace = { model.trace($0) }
                    features.start()
                    AppUpdates.shared.checkAtLaunchIfEnabled()
                }
        }
        .defaultSize(width: 960, height: 680)

        MenuBarExtra(AppVersion.appName, systemImage: model.connected ? "iphone.radiowaves.left.and.right" : "iphone") {
            MenuBarExtraView(model: model, buds: buds, calls: CallingController.shared, hotspots: hotspots)
        }
    }
}
