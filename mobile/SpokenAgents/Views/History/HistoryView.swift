import SwiftUI

struct HistoryView: View {
  @ObservedObject var store: PracticeStore
  @ObservedObject var account: AccountSession
  var coaching: CoachingClient? = nil

  private var visible: [PracticeRecord] {
    store.practices.filter { record in
      store.parts.contains { $0.practiceID == record.id }
        || store.journal.contains { $0.practiceID == record.id } || record.reportData != nil
    }
  }

  var body: some View {
    List {
      if !visible.isEmpty {
        Section {
          HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
              Text("\(visible.count)").font(.system(.title, design: .rounded, weight: .bold))
              Text("Saved conversations").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 5) {
              Text("\(visible.filter { $0.reportData != nil }.count)")
                .font(.system(.title, design: .rounded, weight: .bold)).foregroundStyle(
                  PracticePalette.accent)
              Text("Coaching reports").font(.caption).foregroundStyle(.secondary)
            }
          }.padding(.vertical, 10)
        }
      }
      if visible.isEmpty {
        ContentUnavailableView(
          "No past practices", systemImage: "clock",
          description: Text("Your conversation appears here after you start speaking."))
      }
      ForEach(visible, id: \.id) { record in
        NavigationLink {
          PracticeDetailView(
            store: store, account: account, coaching: coaching, practiceID: record.id)
        } label: {
          VStack(alignment: .leading, spacing: 8) {
            Label(
              record.level + " · " + String(record.durationMinutes) + " min",
              systemImage: "bubble.left.and.bubble.right"
            )
            .font(.caption.weight(.semibold)).foregroundStyle(PracticePalette.accent)
            Text(record.goal).font(.headline)
            Text(record.topic ?? "Agent chooses the topic")
            Text(record.startedAt, style: .date)
            Text("\(record.durationMinutes) min · \(status(record))")
              .foregroundStyle(record.status == "incomplete" ? .orange : .secondary)
          }
          .padding(.vertical, 10)
          .accessibilityElement(children: .combine)
        }
        .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
        .accessibilityIdentifier("practiceRow-\(record.goal)")
      }
    }
    .listStyle(.insetGrouped)
    .tint(PracticePalette.accent)
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
