import Foundation
import Security

protocol AccountBindingStorage {
    func load() -> (accountKey: String, accountID: String)?
    func save(accountKey: String, accountID: String) throws
    func delete()
}

struct AccountBinding: AccountBindingStorage {
    private let service: String
    init(service: String = "com.spokenagents.account-binding") { self.service = service }
    func load() -> (accountKey: String, accountID: String)? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let fields = try? JSONDecoder().decode([String: String].self, from: data),
              let key = fields["key"], let id = fields["id"] else { return nil }
        return (key, id)
    }
    func save(accountKey: String, accountID: String) throws {
        delete()
        guard let data = try? JSONEncoder().encode(["key": accountKey, "id": accountID]) else {
            throw AccountFailure.bindingUnavailable
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw AccountFailure.bindingUnavailable
        }
    }
    func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service] as CFDictionary)
    }
}
