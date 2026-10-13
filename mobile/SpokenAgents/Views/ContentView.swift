import AVFoundation
import SwiftUI

/// Owns navigation and lifecycle; each stage of practice has its own screen.
struct ContentView: View {
  @ObservedObject var call: CallCoordinator
  @ObservedObject var account: AccountSession
  var store: PracticeStore?
  var coaching: CoachingClient?
  @State private var tab = 0
  @State private var showAccount = false
  @State private var selectedScenario: PracticeScenario?
  @State private var session: PresentedPractice?
  @State private var pendingSession: SessionPreferences?
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    TabView(selection: $tab) {
      NavigationStack {
        PracticeHomeView(account: account, store: store, start: openSetup, openHistory: { tab = 1 })
          .navigationTitle("Spoken Agents")
          .navigationBarTitleDisplayMode(.inline)
          .toolbar { accountToolbar }
      }
      .tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
      NavigationStack {
        Group {
          if let store, account.canReadHistory {
            HistoryView(store: store, account: account, coaching: coaching)
          } else {
            ContentUnavailableView {
              Label("Your practice, in one place", systemImage: "clock.arrow.circlepath")
            } description: {
              Text("Sign in to see your conversations and saved coaching.")
            } actions: {
              Button("Sign in") { showAccount = true }.buttonStyle(.borderedProminent)
            }
            .navigationTitle("History")
          }
        }
        .toolbar { accountToolbar }
      }
      .id(account.accountID ?? "signed-out")
      .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }.tag(1)
    }
    .tint(PracticePalette.accent)
    .sheet(isPresented: $showAccount) {
      AccountView(account: account, call: call)
    }
    .sheet(
      item: $selectedScenario,
      onDismiss: {
        if let pendingSession {
          session = PresentedPractice(preferences: pendingSession)
          self.pendingSession = nil
        }
      }
    ) { scenario in
      PracticeSetupView(scenario: scenario) { preferences in
        guard account.canConnect else { return }
        pendingSession = preferences
        selectedScenario = nil
      }
    }
    .fullScreenCover(item: $session) { presented in
      ConversationView(
        call: call, preferences: presented.preferences,
        openHistory: {
          session = nil
          tab = 1
        }
      )
      .task { await call.start(preferences: presented.preferences) }
    }
    .onChange(of: scenePhase) { _, next in
      DiagnosticLog.shared.record("app.scene", fields: ["phase": String(describing: next)])
      if next == .active && account.state == .offline {
        Task { await account.restore() }
      }
      if next == .background {
        Task { await call.stopForInterruption("Practice stopped in the background.") }
      }
    }
    .onChange(of: account.state) { _, next in
      if next != .ready {
        call.accountDidChange()
        session = nil
        selectedScenario = nil
        pendingSession = nil
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) {
      _ in
      DiagnosticLog.shared.record("audio.interruption")
      Task { await call.stopForInterruption("Practice stopped by an audio interruption.") }
    }
    .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) {
      notification in
      let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
      Task { await call.audioRouteChanged(raw) }
    }
  }

  @ToolbarContentBuilder private var accountToolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
      Button {
        showAccount = true
      } label: {
        Image(systemName: account.canReadHistory ? "person.crop.circle.fill" : "person.crop.circle")
          .font(.title2)
          .overlay(alignment: .bottomTrailing) {
            if account.canReadHistory {
              Circle().fill(account.canConnect ? PracticePalette.accent : .orange)
                .frame(width: 9, height: 9).overlay(Circle().stroke(.background, lineWidth: 2))
            }
          }
      }
      .accessibilityLabel(account.canReadHistory ? "Account, signed in" : "Account, signed out")
      .accessibilityValue(account.canConnect ? "Online" : "Offline")
      .accessibilityIdentifier("accountAvatarButton")
    }
  }

  private func openSetup(_ scenario: PracticeScenario) {
    guard account.canConnect else {
      showAccount = true
      return
    }
    selectedScenario = scenario
    pendingSession = nil
  }
}

private struct PresentedPractice: Identifiable {
  let id = UUID()
  let preferences: SessionPreferences
}
