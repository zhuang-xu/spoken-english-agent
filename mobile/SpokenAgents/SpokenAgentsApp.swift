import SwiftUI
import MSAL
import UIKit

@main
struct SpokenAgentsApp: App {
    @UIApplicationDelegateAdaptor(AuthenticationAppDelegate.self) private var appDelegate
    private let store = try? PracticeStore()

    init() {
        DiagnosticLog.shared.record("app.launch", fields: [
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "os": UIDevice.current.systemVersion
        ])
    }

    var body: some Scene {
        WindowGroup {
            if let store {
                AccountRootView(store: store)
            } else {
                ContentUnavailableView("Local storage unavailable", systemImage: "externaldrive.badge.xmark",
                                       description: Text("Speaking practice needs protected local storage. Restart the app or free device space."))
            }
        }
    }
}

private struct AccountRootView: View {
    @StateObject private var account: AccountSession
    @StateObject private var call: CallCoordinator
    let store: PracticeStore

    init(store: PracticeStore) {
        self.store = store
        let account = AccountSession(store: store, authentication: MSALAuthentication())
        _account = StateObject(wrappedValue: account)
        _call = StateObject(wrappedValue: CallCoordinator(
            backend: HTTPBackendClient(account: account), permission: SystemMicrophonePermission(),
            transport: NativeRealtimeTransport(), recorder: WAVTurnRecorder(), store: store,
            coaching: CoachingClient(account: account)
        ))
    }

    var body: some View {
        ContentView(call: call, account: account, store: store)
            .task { await account.restore() }

    }
}

// SwiftUI's onOpenURL omits the source application needed by broker callbacks.
// Use the scene delegate as the single owner of authentication redirect delivery.
final class AuthenticationAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = AuthenticationSceneDelegate.self
        return configuration
    }
}

final class AuthenticationSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        handle(URLContexts)
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        handle(connectionOptions.urlContexts)
    }

    private func handle(_ contexts: Set<UIOpenURLContext>) {
        for context in contexts {
            let handled = MSALPublicClientApplication.handleMSALResponse(
                context.url, sourceApplication: context.options.sourceApplication)
            DiagnosticLog.shared.record("auth.redirect", fields: [
                "handled": String(handled), "source_present": String(context.options.sourceApplication != nil)
            ])
        }
    }
}
