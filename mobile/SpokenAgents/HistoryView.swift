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
                    if let data = record.reportData,
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let summary = object["summary"] as? String { Text(summary) }
                        else { Text("Saved coaching report available offline.") }
                    } else {
                        Text("Feedback is not available yet.")
                    }
                }
                if record.status == "incomplete" || record.status == "ended" {
                    Section("Saved work") {
                        let pending = store.journal.filter { $0.practiceID == practiceID && $0.receipt != "accepted" }
                        Text("\(pending.count) upload items pending")
                        Button(retrying ? "Retrying…" : "Retry pending uploads") {
                            retrying = true
                            Task {
                                store.reconcile()
                                let accepted = await UploadJournalClient().retry(practiceID: practiceID, store: store)
                                note = "\(accepted) saved items accepted. Feedback processing is not available yet."
                                retrying = false
                            }
                        }
                        .disabled(retrying || pending.isEmpty)
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
}
