import AVFoundation
import SwiftUI

struct ContentView: View {
    @ObservedObject var call: CallCoordinator
    @ObservedObject var account: AccountSession
    var store: PracticeStore?
    @State private var goal = "Everyday conversation"
    @State private var level = "B1"
    @State private var topic = ""
    @State private var duration = 10
    @Environment(\.scenePhase) private var scenePhase

    private var preferences: SessionPreferences {
        SessionPreferences(speakingGoal: goal, level: level, preferredTopic: topic.isEmpty ? nil : topic,
                           sessionDurationMinutes: duration).normalized
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    switch account.state {
                    case .ready: Text("Signed in")
                    case .offline: Text("Offline. Saved history is available.")
                    case .checking: ProgressView("Checking sign-in")
                    case .denied: Text("This account cannot access the Spoken Agents API.")
                    case .configurationError: Text("Sign-in is unavailable. Please update the app.")
                    case .needsSignIn: Text(account.signInFailure ?? "Sign-in did not complete. Try again.")
                    case .signedOut: Text("Sign in to practice and view your history.")
                    }
                    if account.state == .offline {
                        Button("Retry connection") { Task { await account.restore() } }
                    }
                    if account.state != .ready && account.state != .checking && account.state != .configurationError {
                        Button("Sign in with Microsoft") {
                            call.accountDidChange()
                            account.signOut()
                            Task { await account.signIn() }
                        }
                        .accessibilityIdentifier("signInButton")
                    }
                    if account.canReadHistory {
                        Button("Sign out", role: .destructive) {
                            call.accountDidChange()
                            account.signOut()
                        }
                    }
                }
                if account.canConnect {
                Section("Practice setup") {
                    TextField("Speaking goal", text: $goal)
                    Picker("CEFR level", selection: $level) {
                        ForEach(["A1", "A2", "B1", "B2", "C1", "C2"], id: \.self) { Text($0) }
                    }
                    TextField("Topic (agent chooses if blank)", text: $topic)
                    Stepper("\(duration) minutes", value: $duration, in: 1...120)
                    if let error = preferences.validationMessage { Text(error).foregroundStyle(.red) }
                    Button("Connect") { Task { await call.start(preferences: preferences) } }
                        .disabled(preferences.validationMessage != nil || ![.idle, .failed, .completed].contains(call.phase))
                }

                Section("Conversation") {
                    Text(call.phase.title)
                        .accessibilityLabel("Practice status: \(call.phase.title)")
                        .accessibilityIdentifier("callStatus")
                    if let message = call.message { Text(message).foregroundStyle(.secondary) }
                    Button("Start speaking") { Task { await call.startTurn() } }
                        .accessibilityHint("Starts a recorded learner turn. Finish the turn when you are done speaking.")
                        .disabled(call.phase != .ready)
                    Button("Finish turn") { Task { await call.finishTurn() } }
                        .accessibilityHint("Sends this turn to the conversation and saves your recording for feedback.")
                        .disabled(call.phase != .recording)
                    Button(call.speakerEnabled ? "Use current audio route" : "Use speaker") { call.toggleSpeaker() }
                        .disabled(![.ready, .recording, .waitingForTranscript].contains(call.phase))
                    Button("End & get feedback") { Task { await call.endAndGetFeedback() } }
                        .disabled(![.connecting, .ready, .preparingTurn, .recording, .waitingForTranscript].contains(call.phase))
                    Button("Disconnect", role: .destructive) { Task { await call.disconnect() } }
                        .disabled(call.phase == .idle || call.phase == .completed)
                    if call.phase == .waitingForTranscript { ProgressView("Transcribing") }
                    if call.phase == .finishing { ProgressView("Ending session") }
                    ForEach(call.parts) { part in
                        Text("\(part.speaker): \(part.text)")
                    }
                }
                }
            }
            .navigationTitle("Spoken Agents")
            .toolbar {
                NavigationLink("Diagnostics") { DiagnosticsView() }
                if let store, account.canReadHistory {
                    NavigationLink("History") { HistoryView(store: store, account: account) }
                }
            }
            .onChange(of: scenePhase) { _, next in
                DiagnosticLog.shared.record("app.scene", fields: ["phase": String(describing: next)])
                if next == .background { Task { await call.stopForInterruption("Practice stopped in the background.") } }
            }
            .onChange(of: account.state) { _, next in
                if next != .ready { call.accountDidChange() }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
                DiagnosticLog.shared.record("audio.interruption")
                Task { await call.stopForInterruption("Practice stopped by an audio interruption.") }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
                let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                Task { await call.audioRouteChanged(raw) }
            }
        }
    }
}
