import SwiftUI
import MSAL
import UIKit

@main
struct SpokenAgentsApp: App {
    @UIApplicationDelegateAdaptor(AuthenticationAppDelegate.self) private var appDelegate
    private let store: PracticeStore?
    #if DEBUG
    private let uiTests: UITestEnvironment?
    #endif

    init() {
        #if DEBUG
        let tests = UITestEnvironment.makeIfRequested()
        uiTests = tests
        store = tests?.store ?? (try? PracticeStore())
        #else
        store = try? PracticeStore()
        #endif
        DiagnosticLog.shared.record("app.launch", fields: [
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "os": UIDevice.current.systemVersion
        ])
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let store {
                if let uiTests {
                    ContentView(call: uiTests.call, account: uiTests.account, store: store, coaching: uiTests.coaching)
                        .task { await uiTests.account.restore() }
                } else { AccountRootView(store: store) }
            } else { Text("Local storage unavailable") }
            #else
            if let store {
                #if DEBUG
                if let uiTests {
                    ContentView(call: uiTests.call, account: uiTests.account, store: store, coaching: uiTests.coaching)
                        .task { await uiTests.account.restore() }
                } else {
                    AccountRootView(store: store)
                }
                #else
                AccountRootView(store: store)
                #endif
            } else {
                ContentUnavailableView("Local storage unavailable", systemImage: "externaldrive.badge.xmark",
                                       description: Text("Speaking practice needs protected local storage. Restart the app or free device space."))
            }
            #endif
        }
    }
}

private struct AccountRootView: View {
    @StateObject private var services: AccountRootServices
    let store: PracticeStore

    init(store: PracticeStore) {
        self.store = store
        // Keep construction inside StateObject's lazy autoclosure. SwiftUI may
        // recreate this view value while retaining its existing services.
        _services = StateObject(wrappedValue: AccountRootServices(store: store))
    }

    var body: some View {
        ContentView(call: services.call, account: services.account, store: store)
            .task { await services.account.restore() }
    }
}

@MainActor
private final class AccountRootServices: ObservableObject {
    let account: AccountSession
    let call: CallCoordinator

    init(store: PracticeStore) {
        let account = AccountSession(store: store, authentication: MSALAuthentication())
        self.account = account
        let capture = WebRTCAudioCapture()
        let transport: RealtimeTransporting = NativeRealtimeTransport(capture: capture)
        #if canImport(WebRTC)
        let recorder: TurnRecording? = capture
        #else
        let recorder: TurnRecording? = nil
        #endif
        call = CallCoordinator(
            backend: HTTPBackendClient(account: account), permission: SystemMicrophonePermission(),
            transport: transport, recorder: recorder, store: store,
            coaching: CoachingClient(account: account)
        )
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
