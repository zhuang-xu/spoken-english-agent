import SwiftUI

struct AccountView: View {
  @ObservedObject var account: AccountSession
  @ObservedObject var call: CallCoordinator
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          VStack(spacing: 14) {
            Image(
              systemName: account.canReadHistory ? "person.crop.circle.fill" : "person.crop.circle"
            )
            .font(.system(size: 72)).foregroundStyle(PracticePalette.accent).accessibilityHidden(
              true)
            Text(account.canReadHistory ? "Your speaking space" : "Make it yours")
              .font(.title2.bold())
            status.multilineTextAlignment(.center).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity).padding(.vertical, 20)
          if account.state == .offline {
            Button("Retry connection") { Task { await account.restore() } }
          }
          if [.signedOut, .needsSignIn, .denied].contains(account.state)
          {
            Button("Sign in with Microsoft") {
              call.accountDidChange()
              Task { await account.signIn() }
            }.accessibilityIdentifier("signInButton")
          }
        }
        Section("App") {
          NavigationLink {
            DiagnosticsView()
          } label: {
            Label("Diagnostics", systemImage: "stethoscope")
          }
        }
        if account.canReadHistory {
          Section {
            Button("Sign out", role: .destructive) {
              call.accountDidChange()
              account.signOut()
            }
          }
        }
      }
      .navigationTitle("Account").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
      .tint(PracticePalette.accent)
    }
  }

  @ViewBuilder private var status: some View {
    switch account.state {
    case .ready: Text("Signed in. Your conversations and coaching are saved to your account.")
    case .offline: Text("Couldn’t reconnect. Your saved account and history are still available.")
    case .checking: ProgressView("Checking sign-in")
    case .denied: Text("This account cannot access the Spoken Agents API.")
    case .configurationError: Text("Sign-in is unavailable. Please update the app.")
    case .needsSignIn: Text(account.signInFailure ?? "Sign-in did not complete. Try again.")
    case .signedOut: Text("Sign in to practice and keep your personal coaching in one place.")
    }
  }
}
