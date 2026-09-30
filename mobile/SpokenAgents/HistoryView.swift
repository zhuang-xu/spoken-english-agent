import SwiftUI

struct HistoryView: View {
    @ObservedObject var store: PracticeStore

    private var visible: [PracticeRecord] {
        store.practices.filter { record in
            store.parts.contains { $0.practiceID == record.id } ||
            store.journal.contains { $0.practiceID == record.id } || record.reportData != nil
        }
    }

    var body: some View {
        List {
            if visible.isEmpty {
                ContentUnavailableView("No past practices", systemImage: "clock", description: Text("Your conversation appears here after you start speaking."))
            }
            ForEach(visible, id: \.id) { record in
                NavigationLink {
                    PracticeDetailView(store: store, practiceID: record.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.goal).font(.headline)
                        Text(record.topic ?? "Agent chooses the topic")
                        Text(record.startedAt, style: .date)
                        Text("\(record.durationMinutes) min · \(status(record))")
                            .foregroundStyle(record.status == "incomplete" ? .orange : .secondary)
                    }
                }
            }
        }
        .navigationTitle("History")
    }

    private func status(_ record: PracticeRecord) -> String {
        switch record.status {
        case "feedbackReady": "Feedback ready"
        case "incomplete": "Saving incomplete"
        case "ended": "Feedback pending"
        case "evaluating": "Feedback processing"
        case "evaluationFailed": "Feedback retry needed"
        default: "Practice interrupted"
        }
    }
}

struct PracticeDetailView: View {
    @ObservedObject var store: PracticeStore
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
        List {
            if let record {
                Section("Practice") {
                    Text(record.goal)
                    Text("\(record.level) · \(record.durationMinutes) min")
                    Text(record.startedAt, style: .date)
                    if let issue = record.issue { Text(issue).foregroundStyle(.orange) }
                    if let note { Text(note).foregroundStyle(.secondary) }
                }
                Section("Conversation") {
                    if conversation.isEmpty { Text("No final transcript was captured.") }
                    ForEach(conversation, id: \.id) { part in
                        VStack(alignment: .leading) {
                            Text(part.speaker).font(.caption).foregroundStyle(.secondary)
                            Text(part.text)
                        }
                    }
                }
                Section("Coaching") {
                    if let report, let result = report.result {
                        Text(result.summary)
                        category("Grammar", result.grammar)
                        category("Vocabulary", result.vocabulary)
                        category("Coherence", result.coherence)
                        speech("Pronunciation", value: report.speechSummary?.averagePronunciation,
                               notAssessed: report.notAssessed.contains("pronunciation"))
                        speech("Spoken fluency", value: report.speechSummary?.averageSpokenFluency,
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
                            Task { note = await CoachingClient().refresh(practiceID: practiceID, store: store) }
                        }
                    } else {
                        Text("Feedback is not available yet.")
                    }
                }
                if ["incomplete", "ended", "evaluating", "evaluationFailed"].contains(record.status) {
                    Section("Saved work") {
                        let pending = store.journal.filter { $0.practiceID == practiceID && $0.receipt != "accepted" }
                        Text("\(pending.count) upload items pending")
                        Button(retrying ? "Retrying…" : "Retry saving and feedback") {
                            retrying = true
                            Task {
                                store.reconcile()
                                note = await CoachingClient().finish(practiceID: practiceID, store: store)
                                retrying = false
                            }
                        }
                        .disabled(retrying)
                    }
                }
                Section {
                    Button("Delete from this device", role: .destructive) { showDelete = true }
                } footer: {
                    Text("This removes local conversation, report, and pending audio. It does not delete server data.")
                }
            }
        }
        .navigationTitle("Practice")
        .confirmationDialog("Delete this practice from this device?", isPresented: $showDelete) {
            Button("Delete from this device", role: .destructive) {
                do { try store.delete(practiceID); dismiss() }
                catch { note = "Could not delete the local practice." }
            }
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
