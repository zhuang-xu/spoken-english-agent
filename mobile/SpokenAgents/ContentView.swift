import AVFoundation
import SwiftUI

struct ContentView: View {
    @ObservedObject var call: CallCoordinator
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
                        .accessibilityIdentifier("callStatus")
                    if let message = call.message { Text(message).foregroundStyle(.secondary) }
                    Button("Start speaking") { Task { await call.startTurn() } }
                        .disabled(call.phase != .ready)
                    Button("Finish turn") { Task { await call.finishTurn() } }
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
            .navigationTitle("Spoken Agents")
            .toolbar {
                if let store {
                    NavigationLink("History") { HistoryView(store: store) }
                }
            }
            .onChange(of: scenePhase) { _, next in
                if next == .background { Task { await call.stopForInterruption("Practice stopped in the background.") } }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
                Task { await call.stopForInterruption("Practice stopped by an audio interruption.") }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
                let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                if raw != AVAudioSession.RouteChangeReason.override.rawValue &&
                   raw != AVAudioSession.RouteChangeReason.categoryChange.rawValue {
                    Task { await call.stopForInterruption("Audio route changed. Start a new practice.") }
                }
            }
        }
    }
}
