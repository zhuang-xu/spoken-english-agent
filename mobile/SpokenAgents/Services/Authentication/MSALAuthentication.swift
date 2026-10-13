import Foundation
import MSAL
import UIKit

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
