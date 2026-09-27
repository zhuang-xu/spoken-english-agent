import SwiftUI

struct ContentView: View {
    @ObservedObject var call: CallCoordinator
    @State private var goal = "Everyday conversation"
    @State private var level = "B1"
    @State private var topic = ""
    @State private var duration = 10

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
                    Button("Connect") {
                        Task {
                            await call.start(preferences: SessionPreferences(
                                speakingGoal: goal,
                                level: level,
                                preferredTopic: topic.isEmpty ? nil : topic,
                                sessionDurationMinutes: duration
                            ))
                        }
                    }
                    .disabled(call.phase != .idle && call.phase != .failed)
                }

                Section("Conversation") {
                    Text(call.phase.title)
                        .accessibilityIdentifier("callStatus")
                    if let message = call.message { Text(message).foregroundStyle(.secondary) }
                    Button("Start speaking") { Task { await call.startTurn() } }
                        .disabled(call.phase != .ready)
                    Button("Finish turn") { Task { await call.finishTurn() } }
                        .disabled(call.phase != .recording)
                    Button("Disconnect", role: .destructive) { Task { await call.disconnect() } }
                        .disabled(call.phase == .idle)
                    ForEach(call.transcripts, id: \.self) { Text($0) }
                }
            }
            .navigationTitle("Spoken Agents")
        }
    }
}
