import SwiftUI

struct PracticeSetupView: View {
  let scenario: PracticeScenario
  let start: (SessionPreferences) -> Void
  @State private var goal: String
  @State private var topic: String
  @State private var level = "B1"
  @State private var duration = 10
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize

  init(scenario: PracticeScenario, start: @escaping (SessionPreferences) -> Void) {
    self.scenario = scenario
    self.start = start
    _goal = State(initialValue: scenario.goal)
    _topic = State(initialValue: scenario.topic)
  }
  private var preferences: SessionPreferences {
    SessionPreferences(
      speakingGoal: goal, level: level, preferredTopic: topic.isEmpty ? nil : topic,
      sessionDurationMinutes: duration
    ).normalized
  }
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          HStack(spacing: 16) {
            Image(systemName: scenario.symbol).font(.title).foregroundStyle(scenario.color)
              .frame(width: 64, height: 64).background(
                scenario.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
            VStack(alignment: .leading, spacing: 5) {
              Text(scenario.title + " practice").font(.title2.bold())
              Text("A few choices, then you’re ready to talk.").font(.subheadline).foregroundStyle(
                .secondary)
            }
          }
          PracticeCard("What would you like to practice?", symbol: "bubble.left.and.bubble.right") {
            Text("Speaking goal").font(.caption).foregroundStyle(.secondary)
            TextField("Speaking goal", text: $goal).accessibilityIdentifier("goalField")
            Text("Topic · optional").font(.caption).foregroundStyle(.secondary)
            TextField("Let your coach choose, or add a topic", text: $topic)
              .accessibilityIdentifier("topicField")
          }
          PracticeCard("Set your pace", symbol: "slider.horizontal.3") {
            Text("Your English level").font(.subheadline.weight(.medium))
            if typeSize.isAccessibilitySize {
              levelPicker.pickerStyle(.menu)
            } else {
              levelPicker.pickerStyle(.segmented)
            }
            Text("Session length").font(.subheadline.weight(.medium))
            Picker("Session length", selection: $duration) {
              ForEach([5, 10, 15], id: \.self) { Text("\($0) min").tag($0) }
            }.pickerStyle(.segmented)
            Stepper("\(duration) minutes", value: $duration, in: 1...120)
            Text("You can finish whenever you like.").font(.caption).foregroundStyle(.secondary)
          }
          Label(
            "Your voice and transcript are saved for personal feedback.", systemImage: "lock.shield"
          )
          .font(.footnote).foregroundStyle(.secondary)
          if let error = preferences.validationMessage {
            Text(error).font(.subheadline).foregroundStyle(.red)
          }
        }.padding(22).frame(maxWidth: 680).frame(maxWidth: .infinity)
      }
      .background(Color(uiColor: .systemGroupedBackground))
      .scrollDismissesKeyboard(.interactively)
      .safeAreaInset(edge: .bottom) {
        Button {
          start(preferences)
        } label: {
          Label("Start conversation", systemImage: "arrow.right")
            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
        }.buttonStyle(.borderedProminent).tint(PracticePalette.action).controlSize(.large)
          .accessibilityIdentifier("connectButton").disabled(preferences.validationMessage != nil)
          .padding(20).background(.bar)
      }
      .navigationTitle("Your session").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }.accessibilityIdentifier("cancelSetupButton")
        }
      }
      .tint(PracticePalette.accent)
    }
    .presentationDetents([.large]).presentationDragIndicator(.visible)
  }

  private var levelPicker: some View {
    Picker("CEFR level", selection: $level) {
      ForEach(["A1", "A2", "B1", "B2", "C1", "C2"], id: \.self) { Text($0).tag($0) }
    }
  }
}
