import SwiftUI

@main
struct SpokenAgentsApp: App {
    @StateObject private var call = CallCoordinator(
        backend: HTTPBackendClient(),
        permission: SystemMicrophonePermission(),
        transport: NativeRealtimeTransport(),
        recorder: WAVTurnRecorder()
    )

    var body: some Scene {
        WindowGroup {
            ContentView(call: call)
        }
    }
}
