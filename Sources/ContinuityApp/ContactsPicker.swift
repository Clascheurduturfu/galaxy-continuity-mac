import SwiftUI
import Contacts

private struct ContactPhone: Identifiable, Sendable {
    let id: String
    let name: String
    let number: String
}

@MainActor private final class ContactsModel: ObservableObject {
    @Published var contacts: [ContactPhone] = []
    @Published var query = ""
    @Published var status = "Choose Load Contacts to allow local, read-only access. Nothing is uploaded."
    @Published var loading = false
    func load() {
        guard !loading else { return }; loading = true
        Task {
            defer { loading = false }
            do {
                let store = CNContactStore()
                guard try await store.requestAccess(for: .contacts) else {
                    status = "Contacts access is off. You can allow it in macOS Privacy & Security settings."; return
                }
                contacts = try await Task.detached(priority: .userInitiated) {
                    let keys = [CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
                    let request = CNContactFetchRequest(keysToFetch: keys); request.sortOrder = .userDefault
                    var values: [ContactPhone] = []
                    try CNContactStore().enumerateContacts(with: request) { contact, stop in
                        guard values.count < 20_000 else { stop.pointee = true; return }
                        let full = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                        for phone in contact.phoneNumbers {
                            values.append(.init(id: contact.identifier + phone.identifier, name: full.isEmpty ? contact.organizationName : full, number: phone.value.stringValue))
                        }
                    }
                    return values
                }.value
                status = contacts.isEmpty ? "No accessible contacts with phone numbers." : "Select a number to fill the dialer. Calling still needs your Call click."
            } catch { status = "Contacts could not be read. Check macOS Contacts permission." }
        }
    }
    var filtered: [ContactPhone] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Array(contacts.lazy.filter { text.isEmpty || $0.name.localizedCaseInsensitiveContains(text) || $0.number.localizedCaseInsensitiveContains(text) }.prefix(100))
    }
}

struct ContactsPicker: View {
    @Binding var number: String
    @StateObject private var model = ContactsModel()
    var body: some View {
        OneUICard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Mac Contacts", systemImage: "person.crop.rectangle.stack").font(.headline)
                    Spacer()
                    if model.loading { ProgressView().controlSize(.small) }
                    Button(model.contacts.isEmpty ? "Load Contacts" : "Refresh") { model.load() }
                        .disabled(model.loading).buttonStyle(OneUISecondaryButtonStyle())
                }
                Text(model.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !model.contacts.isEmpty {
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
                    }.frame(maxHeight: 220)
                    Text("Up to 100 matching numbers shown. Contacts stay in memory while this page is open.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
