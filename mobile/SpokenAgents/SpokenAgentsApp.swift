import SwiftUI

@main
struct SpokenAgentsApp: App {
    private let store: PracticeStore?
    @StateObject private var call: CallCoordinator

    init() {
        let store = try? PracticeStore()
        self.store = store
        _call = StateObject(wrappedValue: CallCoordinator(
            backend: HTTPBackendClient(), permission: SystemMicrophonePermission(),
            transport: NativeRealtimeTransport(), recorder: WAVTurnRecorder(), store: store
        ))
    }

    var body: some Scene {
        WindowGroup {
            if let store {
                ContentView(call: call, store: store)
            } else {
                ContentUnavailableView("Local storage unavailable", systemImage: "externaldrive.badge.xmark",
                                       description: Text("Speaking practice needs protected local storage. Restart the app or free device space."))
            }
        }
    }
}
