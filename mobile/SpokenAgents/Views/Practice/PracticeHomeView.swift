import SwiftUI

struct PracticeHomeView: View {
  @ObservedObject var account: AccountSession
  var store: PracticeStore?
  let start: (PracticeScenario) -> Void
  let openHistory: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        VStack(alignment: .leading, spacing: 6) {
          Text("LET’S TALK").font(.caption.weight(.bold)).tracking(2).foregroundStyle(
            PracticePalette.accent)
          Text("Where will your voice\ntake you today?")
            .font(.system(.largeTitle, design: .rounded, weight: .bold))
        }
        hero
        VStack(alignment: .leading, spacing: 14) {
          Text("Practice for real life").font(.title3.bold())
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
            ForEach(PracticeScenario.all) { scenario in
              Button {
                start(scenario)
              } label: {
                VStack(alignment: .leading, spacing: 12) {
                  Image(systemName: scenario.symbol).font(.title2)
                    .foregroundStyle(scenario.color)
                    .frame(width: 48, height: 48)
                    .background(
                      scenario.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
                  Text(scenario.title).font(.headline).foregroundStyle(.primary)
                  Text(scenario.subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 136, alignment: .leading)
                .padding(18)
                .background(
                  Color(uiColor: .secondarySystemGroupedBackground),
                  in: RoundedRectangle(cornerRadius: 22))
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("scenario-\(scenario.id)")
            }
          }
        }
        if account.canReadHistory, let store {
          RecentPracticeView(store: store, openHistory: openHistory)
        }
      }
      .padding(22).frame(maxWidth: 720).frame(maxWidth: .infinity)
    }
    .background(Color(uiColor: .systemGroupedBackground))
  }

  private var hero: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 10) {
          Text("YOUR AI SPEAKING PARTNER").font(.caption2.bold()).tracking(1.3)
            .foregroundStyle(.white.opacity(0.75))
          Text("A conversation.\nA little more confidence.")
            .font(.system(.title2, design: .rounded, weight: .bold))
        }
        Spacer(minLength: 8)
        Image(systemName: "waveform")
          .font(.system(size: 32, weight: .medium)).frame(width: 64, height: 64)
          .background(.white.opacity(0.12), in: Circle())
          .accessibilityHidden(true)
      }
      Text("Choose a topic. Speak at your pace. Leave with personal coaching.")
        .font(.subheadline).foregroundStyle(.white.opacity(0.85))
      Button {
        start(.everyday)
      } label: {
        HStack {
          Text("Start").font(.headline)
          Spacer()
          Image(systemName: "arrow.up.right").font(.headline)
        }.padding(17).foregroundStyle(PracticePalette.action)
          .background(.white, in: RoundedRectangle(cornerRadius: 16))
      }
      .buttonStyle(.plain).accessibilityIdentifier("startPracticeButton")
      if account.state == .offline {
        Label("Offline · saved coaching is available in History", systemImage: "wifi.slash")
          .font(.caption)
      }
    }
    .foregroundStyle(.white).padding(24)
    .background(
      LinearGradient(
        colors: [PracticePalette.action, Color(red: 0.06, green: 0.25, blue: 0.24)],
        startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 28))
  }
}

private struct RecentPracticeView: View {
  @ObservedObject var store: PracticeStore
  let openHistory: () -> Void
  private var recent: PracticeRecord? {
    store.practices.first { record in
      record.reportData != nil || store.parts.contains { $0.practiceID == record.id }
        || store.journal.contains { $0.practiceID == record.id }
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Keep growing").font(.title3.bold())
        Spacer()
        Button("See history", action: openHistory).font(.subheadline.weight(.semibold))
      }
      Button(action: openHistory) {
        HStack(spacing: 14) {
          Image(systemName: "sparkles").font(.title2).foregroundStyle(PracticePalette.accent)
            .frame(width: 48, height: 48).background(
              PracticePalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
          VStack(alignment: .leading, spacing: 6) {
            Text(recent?.goal ?? "Your next chapter starts here").font(.headline).foregroundStyle(
              .primary)
            Text(
              recent == nil
                ? "Your conversations and coaching will be saved in History."
                : "Revisit your conversation and personal feedback."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
          Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
        }.padding(18).background(
          Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
      }.buttonStyle(.plain)
    }
  }
}
