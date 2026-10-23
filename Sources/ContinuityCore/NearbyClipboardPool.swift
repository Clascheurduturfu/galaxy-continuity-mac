import Foundation

/// Additional account-authenticated clipboard links. Each radio peer gets its
/// own session; discovery is not an unauthenticated clipboard broadcast.
@MainActor public final class NearbyClipboardPool {
    private final class Link {
        let session: ClipboardSession
        var task: Task<Void, Never>?
        var ready = false
        init(_ session: ClipboardSession) { self.session = session }
    }
    private var links: [String: Link] = [:]
    private var retryAfter: [String: Date] = [:]
    private var failures: [String: Int] = [:]
    private var retryTask: Task<Void, Never>?
    private var profile: ContinuityProfile?
    private var candidates: [NearbyPeer] = []
    private var excluded = Set<String>()
    private var enabled = false
    private var sharingEnabled = true
    private let makeSession: (ContinuityProfile) throws -> ClipboardSession
    public var opened: ((ClipboardSession, String) -> Void)?
    public var changed: (() -> Void)?
    public var status: ((String) -> Void)?
    public var sessions: [ClipboardSession] { links.values.filter(\.ready).map(\.session) }
    public var connectedAddresses: [String] { links.filter { $0.value.ready }.map(\.key) }
    public init(makeSession: ((ContinuityProfile) throws -> ClipboardSession)? = nil) {
        self.makeSession = makeSession ?? { ClipboardSession(connection: try BLEMCFTransport(profile: $0), profile: $0) }
    }
    private static func key(_ value: String) -> String { value.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased() }

    public func update(profile: ContinuityProfile?, peers: [NearbyPeer], excluding: [String], enabled: Bool, sharing: Bool = true) {
        if self.profile?.accountKey != profile?.accountKey || self.profile?.localBluetoothAddress != profile?.localBluetoothAddress || self.profile?.revision != profile?.revision { stop() }
        self.profile = profile; candidates = peers; excluded = Set(excluding.map(Self.key)); self.enabled = enabled; sharingEnabled = sharing
        for link in links.values { link.session.clipboardEnabled = sharing }
        reconcile()
    }
    private func reconcile() {
        retryTask?.cancel(); retryTask = nil
        guard enabled, let profile else { removeAll(); return }
        let allowed = Set(profile.peers.filter { ["phone", "tablet", "tab"].contains($0.deviceType?.lowercased() ?? "") }.map { Self.key($0.address) }).subtracting(excluded)
        for address in Array(links.keys) where !allowed.contains(address) { remove(address) }
        var seen = Set<String>()
        for peer in candidates where sharingEnabled && peer.bluetoothConnectable {
            let address = Self.key(peer.address)
            guard allowed.contains(address), seen.insert(address).inserted, links[address] == nil,
                  retryAfter[address, default: .distantPast] <= Date() else { continue }
            var target = profile; target.preferredPeerAddress = peer.address
            do {
                let link = Link(try makeSession(target)); links[address] = link
                link.session.clipboardEnabled = sharingEnabled
                opened?(link.session, peer.name)
                link.task = Task { [weak self, weak link] in
                    guard let self, let link else { return }
                    defer {
                        link.session.stop()
                        if self.links[address] === link {
                            self.links.removeValue(forKey: address)
                            if !Task.isCancelled {
                                let count = min(self.failures[address, default: 0] + 1, 5)
                                self.failures[address] = count
                                self.retryAfter[address] = Date().addingTimeInterval(min(60, Double(1 << count)))
                            }
                            self.changed?(); self.reconcile()
                        }
                    }
                    do {
                        try await link.session.connect(); try Task.checkCancellation()
                        guard self.links[address] === link else { return }
                        link.ready = true; self.failures[address] = 0; self.retryAfter[address] = nil
                        self.changed?()
                        try await link.session.run()
                    } catch { if !Task.isCancelled { self.status?("A nearby clipboard link ended; it will retry while that device is discoverable.") } }
                }
            } catch { retryAfter[address] = Date().addingTimeInterval(60) }
        }
        // A single bounded retry wake-up, only for currently advertised peers.
        let advertised = Set(candidates.filter(\.bluetoothConnectable).map { Self.key($0.address) })
        if sharingEnabled, let next = retryAfter.filter({ allowed.contains($0.key) && advertised.contains($0.key) && links[$0.key] == nil }).map(\.value).min() {
            let delay = max(0.5, next.timeIntervalSinceNow)
            retryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }; self?.reconcile()
            }
        }
    }
    private func remove(_ address: String) { guard let link = links.removeValue(forKey: address) else { return }; link.task?.cancel(); link.session.stop() }
    private func removeAll() { let hadLinks = !links.isEmpty; for address in Array(links.keys) { remove(address) }; if hadLinks { changed?() } }
    public func stop() { enabled = false; retryTask?.cancel(); retryTask = nil; removeAll(); retryAfter.removeAll(); failures.removeAll() }
}
