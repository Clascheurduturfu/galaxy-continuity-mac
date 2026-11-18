import SwiftUI
import Contacts
import Darwin
import ContinuityCore

struct ContactPhone: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let name: String
    let number: String
}

@MainActor final class ContactsStore: ObservableObject {
    static let shared = ContactsStore()

    @Published var contacts: [ContactPhone] = []
    @Published var query = ""
    @Published var status = "Choose Load Contacts to allow local, read-only access. Nothing is uploaded."
    @Published var loading = false

    private var didChangeObserver: NSObjectProtocol?
    private var lastFetchAt: Date = .distantPast

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Galaxy Continuity Lab", isDirectory: true)
    }
    private static var cacheFile: URL {
        cacheDirectory.appendingPathComponent("contacts-cache.json", isDirectory: false)
    }

    init() {
        loadFromCacheIfAuthorized()
        didChangeObserver = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshIfAuthorized(force: true)
            }
        }
    }

    func refreshIfAuthorized(force: Bool = false) {
        let auth = CNContactStore.authorizationStatus(for: .contacts)
        switch auth {
        case .authorized:
            if contacts.isEmpty { loadFromCacheIfAuthorized() }
            if force || contacts.isEmpty || Date().timeIntervalSince(lastFetchAt) > 300 {
                fetchContacts(requestPromptIfNeeded: false)
            }
        case .denied, .restricted:
            contacts = []
            status = "Contacts access is off. You can allow it in macOS Privacy & Security settings."
        case .notDetermined:
            contacts = []
        @unknown default:
            break
        }
    }

    func load() {
        fetchContacts(requestPromptIfNeeded: true)
    }

    func name(forPhoneNumber raw: String) -> String? {
        let target = CallingEmergencyGuard.sanitizeDigits(raw)
        let targetPure = target.filter(\.isNumber)
        guard targetPure.count >= 3 else { return nil }
        let targetTail = targetPure.count >= 9 ? String(targetPure.suffix(9)) : targetPure
        for entry in contacts {
            let candidate = CallingEmergencyGuard.sanitizeDigits(entry.number)
            let candidatePure = candidate.filter(\.isNumber)
            guard !candidatePure.isEmpty, !entry.name.isEmpty else { continue }
            if candidate == target || candidatePure == targetPure {
                return entry.name
            }
            if targetPure.count >= 7 && candidatePure.count >= 7 {
                let candidateTail = candidatePure.count >= 9 ? String(candidatePure.suffix(9)) : candidatePure
                if candidateTail == targetTail {
                    return entry.name
                }
            }
        }
        return nil
    }

    var filtered: [ContactPhone] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Array(contacts.lazy.filter {
            text.isEmpty || $0.name.localizedCaseInsensitiveContains(text) || $0.number.localizedCaseInsensitiveContains(text)
        }.prefix(100))
    }

    private func fetchContacts(requestPromptIfNeeded: Bool) {
        guard !loading else { return }
        let currentStatus = CNContactStore.authorizationStatus(for: .contacts)
        if !requestPromptIfNeeded && currentStatus != .authorized { return }
        loading = true
        Task {
            defer { loading = false }
            do {
                if currentStatus != .authorized {
                    let store = CNContactStore()
                    guard try await store.requestAccess(for: .contacts) else {
                        contacts = []
                        status = "Contacts access is off. You can allow it in macOS Privacy & Security settings."
                        return
                    }
                }
                let fetched = try await Task.detached(priority: .userInitiated) {
                    let keys = [
                        CNContactIdentifierKey,
                        CNContactGivenNameKey,
                        CNContactFamilyNameKey,
                        CNContactOrganizationNameKey,
                        CNContactPhoneNumbersKey
                    ] as [CNKeyDescriptor]
                    let request = CNContactFetchRequest(keysToFetch: keys)
                    request.sortOrder = .userDefault
                    var values: [ContactPhone] = []
                    try CNContactStore().enumerateContacts(with: request) { contact, stop in
                        guard values.count < 20_000 else { stop.pointee = true; return }
                        let full = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                        let display = full.isEmpty ? contact.organizationName : full
                        for phone in contact.phoneNumbers {
                            values.append(.init(id: contact.identifier + phone.identifier, name: display, number: phone.value.stringValue))
                        }
                    }
                    return values
                }.value
                contacts = fetched
                lastFetchAt = Date()
                status = fetched.isEmpty
                    ? "No accessible contacts with phone numbers."
                    : "Select a number to fill the dialer, or type to search (\(fetched.count) cached)."
                saveCache(fetched)
            } catch {
                if contacts.isEmpty {
                    status = "Contacts could not be read. Check macOS Contacts permission."
                }
            }
        }
    }

    private func loadFromCacheIfAuthorized() {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }
        var info = stat()
        let path = Self.cacheFile.path
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              let data = try? Data(contentsOf: Self.cacheFile),
              let cached = try? JSONDecoder().decode([ContactPhone].self, from: data),
              !cached.isEmpty else { return }
        contacts = cached
        status = "Select a number to fill the dialer, or type to search (\(cached.count) cached)."
    }

    private func saveCache(_ entries: [ContactPhone]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = chmod(Self.cacheDirectory.path, 0o700)
        var info = stat()
        if lstat(Self.cacheFile.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else { return }
        }
        try? data.write(to: Self.cacheFile, options: .atomic)
        _ = chmod(Self.cacheFile.path, 0o600)
    }
}

struct ContactsPicker: View {
    @Binding var number: String
    @ObservedObject private var model = ContactsStore.shared
    var body: some View {
        OneUICard(fillHeight: true) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Mac Contacts", systemImage: "person.crop.rectangle.stack").font(.headline)
                    Spacer()
                    if model.loading { ProgressView().controlSize(.small) }
                    Button(model.contacts.isEmpty ? "Load Contacts" : "Refresh") { model.load() }
                        .disabled(model.loading).buttonStyle(OneUISecondaryButtonStyle())
                }
                if model.contacts.isEmpty {
                    Text(model.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    TextField("Search contacts or numbers", text: $model.query).textFieldStyle(.roundedBorder)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(model.filtered) { contact in
                                Button { number = contact.number } label: {
                                    HStack { Text(contact.name.isEmpty ? "Contact" : contact.name); Spacer(); Text(contact.number).foregroundStyle(.secondary) }
                                        .padding(7).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(height: 196)
                    Text("Up to 100 matching numbers shown (\(model.contacts.count) cached). Cached locally once allowed.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { model.refreshIfAuthorized() }
    }
}
