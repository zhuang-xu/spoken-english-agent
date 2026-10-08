import Foundation
import Security
import MSAL
import UIKit

struct NativeIdentity {
    let accountKey: String
    let token: String
}

@MainActor protocol NativeAuthentication {
    func cachedAccountKeys() throws -> [String]
    func acquireSilently(accountKey: String) async throws -> NativeIdentity
    func acquireInteractively() async throws -> NativeIdentity
    func remove(accountKey: String) throws
}

enum AccountFailure: Error, Equatable {
    case signedOut, changed, configuration, invalidIdentity, bindingUnavailable
}

@MainActor final class AccountSession: ObservableObject {
    enum State: Equatable { case signedOut, checking, ready, offline, needsSignIn, denied, configurationError }
    @Published private(set) var state: State = .signedOut {
        didSet { DiagnosticLog.shared.record("auth.state", fields: ["state": String(describing: state)]) }
    }
    @Published private(set) var accountID: String?
    @Published private(set) var signInFailure: String?
    private(set) var generation = UUID()
    private var accountKey: String?
    private let authentication: NativeAuthentication?
    private let store: PracticeStore
    private let session: URLSession
    private let baseURL: URL
    private let binding: any AccountBindingStorage

    init(store: PracticeStore, authentication: NativeAuthentication?, baseURL: URL? = nil,
         session: URLSession = .shared, binding: any AccountBindingStorage = AccountBinding()) {
        self.store = store
        self.authentication = authentication
        let configured = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String
        self.baseURL = baseURL ?? URL(string: configured ?? "") ?? URL(string: "http://127.0.0.1:8000")!
        self.session = session
        self.binding = binding
        store.switchAccount(to: "")
        if authentication == nil { state = .configurationError }
    }

    var canReadHistory: Bool { accountID != nil }
    var canConnect: Bool { state == .ready }

    func restore() async {
        DiagnosticLog.shared.record("auth.restore")
        guard let authentication else { state = .configurationError; return }
        state = .checking
        do {
            let keys = try authentication.cachedAccountKeys()
            guard let saved = binding.load(), keys.contains(saved.accountKey) else {
                state = .signedOut; return
            }
            // The cached MSAL account and its previously verified server ID must agree.
            select(accountKey: saved.accountKey, accountID: saved.accountID)
            state = .offline
            do {
                let identity = try await authentication.acquireSilently(accountKey: saved.accountKey)
                guard accountKey == saved.accountKey else { return }
                let verified = try await verify(identity)
                guard accountKey == saved.accountKey else { return }
                if verified != saved.accountID { clearSelection(); state = .needsSignIn; return }
                state = .ready
            } catch BackendFailure.status(401) { clearSelection(); state = .needsSignIn }
              catch BackendFailure.status(403) { clearSelection(); state = .denied }
              catch {
                  if accountKey == saved.accountKey {
                      state = (error as NSError).domain == NSURLErrorDomain ? .offline : .needsSignIn
                  }
              }
        } catch { state = .needsSignIn }
    }

    func signIn() async {
        DiagnosticLog.shared.record("auth.sign_in")
        guard let authentication else { state = .configurationError; return }
        let start = generation
        signInFailure = nil
        var stage = "Microsoft authentication"
        state = .checking
        do {
            let identity = try await authentication.acquireInteractively()
            guard generation == start else { return }
            DiagnosticLog.shared.record("auth.token_acquired")
            stage = "API account verification"
            let verified = try await verify(identity)
            guard generation == start else { return }
            try binding.save(accountKey: identity.accountKey, accountID: verified)
            select(accountKey: identity.accountKey, accountID: verified)
            state = .ready
        } catch AccountFailure.bindingUnavailable { if generation == start { state = .configurationError } }
          catch BackendFailure.status(403) { if generation == start { state = .denied } }
          catch {
              if generation == start {
                  DiagnosticLog.shared.failure("auth.sign_in_failure", error: error, fields: ["stage": stage])
                  // Show only stage and error codes, never tokens or broker response URLs.
                  if case BackendFailure.status(let status) = error {
                      signInFailure = "\(stage) failed (HTTP \(status))."
                  } else {
                      let failure = error as NSError
                      signInFailure = "\(stage) failed (\(failure.domain), \(failure.code))."
                  }
                  state = .needsSignIn
              }
          }
    }

    func signOut() {
        DiagnosticLog.shared.record("auth.sign_out")
        signInFailure = nil
        let old = accountKey
        clearSelection()
        binding.delete()
        if let old { try? authentication?.remove(accountKey: old) }
        state = .signedOut
    }


    func lease() throws -> (String, UUID) {
        guard let accountID, accountKey != nil else { throw AccountFailure.signedOut }
        return (accountID, generation)
    }

    func isCurrent(_ owner: String, generation: UUID) -> Bool {
        accountID == owner && self.generation == generation
    }

    func send(_ original: URLRequest, using network: URLSession,
              expected: (String, UUID)? = nil) async throws -> (Data, HTTPURLResponse) {
        let (owner, epoch) = try lease()
        if let expected, (expected.0 != owner || expected.1 != epoch) { throw AccountFailure.changed }
        guard let accountKey, let authentication else { throw AccountFailure.signedOut }
        let identity: NativeIdentity
        do { identity = try await authentication.acquireSilently(accountKey: accountKey) }
        catch {
            if isCurrent(owner, generation: epoch) {
                state = (error as NSError).domain == NSURLErrorDomain ? .offline : .needsSignIn
            }
            throw error
        }
        guard isCurrent(owner, generation: epoch), identity.accountKey == accountKey else { throw AccountFailure.changed }
        var request = original
        request.setValue("Bearer \(identity.token)", forHTTPHeaderField: "Authorization")
        request.setValue(owner, forHTTPHeaderField: "X-Expected-Account-ID")
        let (data, response) = try await DiagnosticHTTP.send(request, using: network)
        guard isCurrent(owner, generation: epoch) else { throw AccountFailure.changed }
        if response.statusCode == 401 { state = .needsSignIn }
        if response.statusCode == 403 { state = .denied }
        if response.statusCode == 409 && response.value(forHTTPHeaderField: "X-Account-Changed") == "1" {
            clearSelection(); state = .needsSignIn
            throw AccountFailure.changed
        }
        return (data, response)
    }

    private func verify(_ identity: NativeIdentity) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "me"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(identity.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await DiagnosticHTTP.send(request, using: session)
        guard response.statusCode == 200 else { throw BackendFailure.status(response.statusCode) }
        struct Me: Decodable { let accountID: String; enum CodingKeys: String, CodingKey { case accountID = "account_id" } }
        let id = try JSONDecoder().decode(Me.self, from: data).accountID
        guard UUID(uuidString: id) != nil else { throw AccountFailure.invalidIdentity }
        return id
    }

    private func select(accountKey: String, accountID: String) {
        generation = UUID()
        self.accountKey = accountKey
        self.accountID = accountID
        store.switchAccount(to: accountID)
        store.reconcile()
    }

    private func clearSelection() {
        generation = UUID()
        accountKey = nil
        accountID = nil
        store.switchAccount(to: "")
    }
}

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

@MainActor final class MSALAuthentication: NativeAuthentication {
    private let application: MSALPublicClientApplication
    private let scope: String

    init?() {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "EntraClientID") as? String,
              !clientID.isEmpty, !clientID.contains("$("),
              let scope = Bundle.main.object(forInfoDictionaryKey: "EntraAPIScope") as? String,
              !scope.isEmpty, !scope.contains("$("),
              let tenant = Bundle.main.object(forInfoDictionaryKey: "EntraTenantID") as? String,
              !tenant.isEmpty, !tenant.contains("$("),
              let authorityURL = URL(string: "https://login.microsoftonline.com/\(tenant)"),
              let authority = try? MSALAADAuthority(url: authorityURL) else { return nil }
        let config = MSALPublicClientApplicationConfig(clientId: clientID)
        config.authority = authority
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        config.redirectUri = "msauth.\(bundleID)://auth"
        guard let application = try? MSALPublicClientApplication(configuration: config) else { return nil }
        self.application = application
        self.scope = scope
    }

    func cachedAccountKeys() throws -> [String] { try application.allAccounts().compactMap(\.identifier) }

    func acquireSilently(accountKey: String) async throws -> NativeIdentity {
        let account = try application.account(forIdentifier: accountKey)
        let parameters = MSALSilentTokenParameters(scopes: [scope], account: account)
        return try await withCheckedThrowingContinuation { continuation in
            application.acquireTokenSilent(with: parameters) { result, error in
                if let result, let key = result.account.identifier {
                    continuation.resume(returning: NativeIdentity(accountKey: key, token: result.accessToken))
                }
                else {
                    let failure = error ?? AccountFailure.signedOut
                    DiagnosticLog.shared.failure("auth.token_failure", error: failure)
                    continuation.resume(throwing: failure)
                }
            }
        }
    }

    func acquireInteractively() async throws -> NativeIdentity {
        guard let presenter = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else {
            throw AccountFailure.configuration
        }
        let web = MSALWebviewParameters(authPresentationViewController: presenter)
        let parameters = MSALInteractiveTokenParameters(scopes: [scope], webviewParameters: web)
        return try await withCheckedThrowingContinuation { continuation in
            application.acquireToken(with: parameters) { result, error in
                if let result, let key = result.account.identifier {
                    continuation.resume(returning: NativeIdentity(accountKey: key, token: result.accessToken))
                }
                else {
                    let failure = error ?? AccountFailure.signedOut
                    DiagnosticLog.shared.failure("auth.token_failure", error: failure)
                    continuation.resume(throwing: failure)
                }
            }
        }
    }

    func remove(accountKey: String) throws {
        let account = try application.account(forIdentifier: accountKey)
        _ = try application.remove(account)
    }

}
