import SwiftUI

struct DiagnosticsView: View {
    @State private var exportURL: URL?
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Text("Logs record sign-in, requests, audio setup, and connection states. Tokens, audio, and conversation text are excluded.")
                Button("Refresh diagnostic log") { refresh() }
                if let exportURL {
                    ShareLink("Share diagnostic log", item: exportURL)
                }
                if let problem { Text(problem).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Diagnostics")
        .onAppear { refresh() }
    }

    private func refresh() {
        do { exportURL = try DiagnosticLog.shared.export(); problem = nil }
        catch { problem = "Could not prepare the log. Try again." }
    }
}
