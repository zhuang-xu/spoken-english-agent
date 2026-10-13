import SwiftUI

struct PracticeDetailView: View {
  @ObservedObject var store: PracticeStore
  @ObservedObject var account: AccountSession
  var coaching: CoachingClient? = nil
  let practiceID: UUID
  @State private var showDelete = false
  @State private var retrying = false
  @State private var note: String?
  @Environment(\.dismiss) private var dismiss

  private var record: PracticeRecord? { store.practices.first { $0.id == practiceID } }
  private var report: CoachingResponse? {
    guard let data = record?.reportData else { return nil }
    return try? JSONDecoder().decode(CoachingResponse.self, from: data)
  }
  private var conversation: [SavedPart] {
    store.parts.filter { $0.practiceID == practiceID && !$0.text.isEmpty }
      .sorted { $0.offsetMilliseconds < $1.offsetMilliseconds }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if let record {
          PracticeCard("Practice", symbol: "book.closed") {
            Text(record.goal).font(.title2.weight(.bold))
            Text("\(record.level) · \(record.durationMinutes) min")
            Text(record.startedAt, style: .date)
            if let issue = record.issue { Text(issue).foregroundStyle(.orange) }
            if let note { Text(note).foregroundStyle(.secondary) }
          }
          PracticeCard("Conversation", symbol: "bubble.left.and.bubble.right") {
            if conversation.isEmpty { Text("No final transcript was captured.") }
            ForEach(conversation, id: \.id) { part in
              VStack(alignment: .leading) {
                Text(part.speaker).font(.caption).foregroundStyle(.secondary)
                Text(part.text)
              }
              .accessibilityElement(children: .combine)
            }
          }
          PracticeCard("Coaching", symbol: "sparkles") {
            if let report, let result = report.result {
              Text(result.summary)
              category("Grammar", result.grammar)
              category("Vocabulary", result.vocabulary)
              category("Coherence", result.coherence)
              speech(
                "Pronunciation", value: report.speechSummary?.averagePronunciation,
                notAssessed: report.notAssessed.contains("pronunciation"))
              speech(
                "Spoken fluency", value: report.speechSummary?.averageSpokenFluency,
                notAssessed: report.notAssessed.contains("spoken_fluency"))
              if let rhythm = report.speechSummary?.averageRhythmAndIntonation {
                Text("Rhythm and intonation: \(rhythm)/100")
              }
              VStack(alignment: .leading) {
                Text("Strengths").font(.headline)
                ForEach(result.strengths, id: \.self) { Text("• \($0)") }
              }
              VStack(alignment: .leading) {
                Text("Next steps").font(.headline)
                ForEach(Array(result.nextSteps.enumerated()), id: \.offset) { index, step in
                  Text("\(index + 1). \(step)")
                }
              }
              if !result.corrections.isEmpty {
                Text("Grounded corrections").font(.headline)
                ForEach(result.corrections) { correction in
                  VStack(alignment: .leading) {
                    Text("“\(correction.original)” → “\(correction.improved)”")
                    Text(correction.explanation).foregroundStyle(.secondary)
                  }
                }
              }
              Button("Refresh report online") {
                Task {
                  note = await (coaching ?? CoachingClient(account: account)).refresh(
                    practiceID: practiceID, store: store)
                }
              }
              .accessibilityIdentifier("refreshReportButton")
              .disabled(!account.canConnect)
            } else {
              Text("Feedback is not available yet.")
            }
          }
          if ["incomplete", "ended", "evaluating", "evaluationFailed"].contains(record.status) {
            PracticeCard("Saved work", symbol: "arrow.triangle.2.circlepath") {
              let pending = store.journal.filter {
                $0.practiceID == practiceID && $0.receipt == "pending"
              }
              let rejected = store.journal.filter {
                $0.practiceID == practiceID && $0.receipt == "rejected"
              }
              if !rejected.isEmpty {
                Text("\(rejected.count) recordings could not be saved")
                Text("These recordings could not be processed. Retrying cannot repair them. Start a new practice.")
                  .foregroundStyle(.secondary)
              }
              if !pending.isEmpty { Text("\(pending.count) upload items pending") }
              if rejected.isEmpty && pending.isEmpty { Text("Conversation saved") }
              Button(retrying ? "Retrying…" : "Retry saving and feedback") {
                retrying = true
                Task {
                  store.reconcile()
                  note = await (coaching ?? CoachingClient(account: account)).finish(
                    practiceID: practiceID, store: store)
                  retrying = false
                }
              }
              .accessibilityIdentifier("retryFeedbackButton")
              .disabled(retrying || !account.canConnect || (!rejected.isEmpty && pending.isEmpty))
            }
          }
          PracticeCard("Manage practice", symbol: "externaldrive") {
            Button("Delete from this device", role: .destructive) { showDelete = true }
              .accessibilityIdentifier("deletePracticeButton")

            Text(
              "This removes local conversation, report, and pending audio. It does not delete server data."
            ).font(.footnote).foregroundStyle(.secondary)
          }
        }
      }
      .padding(20)
      .frame(maxWidth: 680)
      .frame(maxWidth: .infinity)
    }
    .background(Color(uiColor: .systemGroupedBackground))
    .tint(PracticePalette.accent)
    .navigationTitle("Practice")
    .confirmationDialog("Delete this practice from this device?", isPresented: $showDelete) {
      Button("Delete from this device", role: .destructive) {
        do {
          try store.delete(practiceID)
          dismiss()
        } catch { note = "Could not delete the local practice." }
      }
      .accessibilityIdentifier("confirmDeletePracticeButton")
    }
  }

  private func category(_ name: String, _ category: CoachingCategory) -> some View {
    VStack(alignment: .leading) {
      Text("\(name): \(category.score.map { "\($0)/5" } ?? "Not assessed")").font(.headline)
      Text(category.feedback)
    }
  }

  private func speech(_ name: String, value: Int?, notAssessed: Bool) -> some View {
    let assessment = value.map { "\($0)/100" } ?? "Not assessed"
    return Text("\(name): \(notAssessed ? "Not assessed" : assessment)")
  }
}
