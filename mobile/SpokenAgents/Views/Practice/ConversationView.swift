import SwiftUI

struct ConversationView: View {
  @ObservedObject var call: CallCoordinator
  let preferences: SessionPreferences
  let openHistory: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var confirmLeave = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var canEnd: Bool {
    [.connecting, .ready, .preparingTurn, .recording, .finalizingTurn, .waitingForTranscript].contains(call.phase)
  }
  private var canLeave: Bool { [.idle, .failed, .completed].contains(call.phase) }

  var body: some View {
    NavigationStack {
      ScrollViewReader { reader in
        ScrollView {
          VStack(spacing: 22) {
            VStack(spacing: 14) {
              ZStack {
                Circle().fill(PracticePalette.accent.opacity(0.07)).frame(width: 148, height: 148)
                Circle().stroke(PracticePalette.accent.opacity(0.15), lineWidth: 1).frame(
                  width: 120, height: 120)
                Image(systemName: call.phase == .recording ? "mic.fill" : "waveform")
                  .font(.system(size: 40, weight: .medium)).foregroundStyle(PracticePalette.accent)
                  .frame(width: 92, height: 92)
                  .background(PracticePalette.accent.opacity(0.12), in: Circle())
              }.accessibilityHidden(true)
              Text(call.phase.title).font(.headline)
                .accessibilityLabel("Practice status: \(call.phase.title)")
                .accessibilityIdentifier("callStatus")
              Text(preferences.speakingGoal).font(.subheadline).foregroundStyle(.secondary)
              Text("\(preferences.level) · \(preferences.sessionDurationMinutes) min")
                .font(.caption.weight(.semibold)).foregroundStyle(PracticePalette.accent)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(PracticePalette.accent.opacity(0.08), in: Capsule())
            }.frame(maxWidth: .infinity).padding(.top, 8)
            if let message = call.message {
              Text(message).font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(
                  Color(uiColor: .secondarySystemGroupedBackground),
                  in: RoundedRectangle(cornerRadius: 16))
            }
            if call.parts.isEmpty && ![.completed, .failed].contains(call.phase) {
              VStack(spacing: 8) {
                Text(call.phase == .recording ? "You have the floor" : "A space to speak freely")
                  .font(.title3.weight(.semibold))
                Text("Tap the microphone to speak. Finish your turn when you’re ready for a reply.")
                  .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
              }.padding(.vertical, 14)
            }
            ForEach(call.parts) { part in
              HStack(alignment: .bottom, spacing: 8) {
                if part.speaker == "You" { Spacer(minLength: 36) }
                Text("\(part.speaker): \(part.text)")
                  .padding(16).frame(alignment: .leading)
                  .background(
                    part.speaker == "You"
                      ? PracticePalette.accent.opacity(0.12)
                      : Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 20))
                if part.speaker != "You" { Spacer(minLength: 36) }
              }
            }
            if [
              .connecting, .requestingPermission, .preparingTurn, .finalizingTurn, .waitingForTranscript, .finishing,
              .evaluating,
            ].contains(call.phase) {
              ProgressView(call.phase.title).padding(.vertical, 8)
            }
            Color.clear.frame(height: 1).id("conversationBottom")
          }.padding(22).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .onChange(of: call.parts.count) { _, _ in
          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            reader.scrollTo("conversationBottom", anchor: .bottom)
          }
        }
      }
      .background(Color(uiColor: .systemGroupedBackground))
      .safeAreaInset(edge: .bottom) { controls }
      .navigationTitle("Conversation").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            if canLeave { dismiss() } else { confirmLeave = true }
          } label: {
            Image(systemName: "xmark")
          }
          .accessibilityLabel("Close conversation").accessibilityIdentifier(
            "closeConversationButton")
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("End conversation") { confirmLeave = true }
            .accessibilityIdentifier("disconnectButton").disabled(
              call.phase == .idle || call.phase == .completed)
        }
      }
      .sheet(isPresented: $confirmLeave) {
        VStack(alignment: .leading, spacing: 18) {
          Text("Finish this conversation?").font(.title2.bold())
          Text(call.supportsAudioFeedback
            ? "Get personal coaching, or finish now and keep your conversation saved."
            : "Keep your conversation saved. Audio feedback is currently unavailable.")
            .foregroundStyle(.secondary)
          Button("Finish & get feedback") {
            confirmLeave = false
            Task { await call.endAndGetFeedback() }
          }.buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!call.supportsAudioFeedback)
            .accessibilityIdentifier("feedbackButton")
            .disabled(!canEnd)
          Button("End without feedback", role: .destructive) {
            confirmLeave = false
            // Keep cleanup alive after dismissal without waiting on the server.
            Task { await call.disconnect() }
            dismiss()
          }
          Button("Cancel") { confirmLeave = false }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
      }
      .tint(PracticePalette.accent)
    }
    .interactiveDismissDisabled()
  }

  private var controls: some View {
    VStack(spacing: 14) {
      if call.phase == .completed {
        Button(action: openHistory) {
          Label("View saved feedback", systemImage: "sparkles").frame(maxWidth: .infinity).padding(
            .vertical, 9)
        }
        .buttonStyle(.borderedProminent).tint(PracticePalette.action).controlSize(.large)
        .accessibilityIdentifier("viewFeedbackButton")
      } else if [.idle, .failed].contains(call.phase) {
        Button {
          Task { await call.start(preferences: preferences) }
        } label: {
          Label("Try again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
            .padding(.vertical, 9)
        }.buttonStyle(.borderedProminent).tint(PracticePalette.action).controlSize(.large)
          .accessibilityIdentifier("connectButton")
      } else {
        HStack(spacing: 22) {
          Button {
            call.toggleSpeaker()
          } label: {
            Image(systemName: call.speakerEnabled ? "speaker.wave.2.fill" : "speaker.fill")
              .font(.title3).frame(width: 48, height: 48)
              .background(PracticePalette.accent.opacity(0.08), in: Circle())
          }.accessibilityLabel(call.speakerEnabled ? "Use current audio route" : "Use speaker")
            .disabled(![.ready, .recording, .waitingForTranscript].contains(call.phase))
          Button {
            Task {
              if call.phase == .recording {
                await call.finishTurn()
              } else {
                await call.startTurn()
              }
            }
          } label: {
            Image(systemName: call.phase == .recording ? "stop.fill" : "mic.fill")
              .font(.system(size: 28)).foregroundStyle(.white).frame(width: 76, height: 76)
              .background(
                call.phase == .recording ? Color.red : PracticePalette.action, in: Circle())
          }
          .accessibilityLabel(call.phase == .recording ? "Finish turn" : "Start speaking")
          .accessibilityIdentifier(
            call.phase == .recording ? "finishTurnButton" : "startTurnButton"
          )
          .accessibilityHint("Records one turn for your conversation and personal feedback.")
          .disabled(call.phase != .ready && call.phase != .recording)
          .opacity(call.phase == .ready || call.phase == .recording ? 1 : 0.45)

        }
        Text(call.phase == .recording ? "Finish turn when you’re done" : "Tap to speak")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity).padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 12)
    .background(.bar)
  }
}
