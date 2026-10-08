import Foundation

struct UploadJournalClient {
    let baseURL: URL
    let session: URLSession
    let account: AccountSession?

    init(baseURL: URL? = nil, session: URLSession = .shared, account: AccountSession? = nil) {
        let configured = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String
        self.baseURL = baseURL ?? URL(string: configured ?? "") ?? URL(string: "http://127.0.0.1:8000")!
        self.session = session
        self.account = account
    }

    @MainActor func retry(practiceID: UUID, store: PracticeStore) async -> Int {
        guard let practice = store.practices.first(where: { $0.id == practiceID }) else { return 0 }
        let lease = try? account?.lease()
        var accepted = 0
        for item in store.journal.filter({ $0.practiceID == practiceID && $0.receipt != "accepted" }) {
            guard store.accountID == practice.owner,
                  account == nil || (lease != nil && account?.isCurrent(lease!.0, generation: lease!.1) == true) else { break }
            do {
                let bytes = try store.bytes(for: item)
                let path = try route(for: item, sessionID: practice.sessionID)
                var request = URLRequest(url: baseURL.appending(path: path))
                request.httpMethod = "PUT"
                request.httpBody = bytes
                request.timeoutInterval = item.kind == "audio" ? 90 : 30
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue(item.contentType, forHTTPHeaderField: "Content-Type")
                let response: HTTPURLResponse
                if let account { (_, response) = try await account.send(request, using: session, expected: lease) }
                else {
                    let (_, raw) = try await session.data(for: request)
                    guard let valid = raw as? HTTPURLResponse else { throw BackendFailure.invalidResponse }
                    response = valid
                }
                guard response.statusCode == 200 || response.statusCode == 201 else {
                    throw BackendFailure.status(response.statusCode)
                }
                guard store.accountID == practice.owner else { break }
                try store.markAccepted(item.id, practiceID: practiceID)
                accepted += 1
            } catch {
                guard store.accountID == practice.owner,
                      account == nil || (lease != nil && account?.isCurrent(lease!.0, generation: lease!.1) == true) else { break }
                item.issue = (error as? BackendFailure) == .status(409)
                    ? "Saved content conflicts with the server. Local bytes were preserved."
                    : (error as? BackendFailure) == .status(429)
                        ? "Request limit reached. Wait a minute, then retry this saved upload."
                        : "Upload pending. Try again when connected."
                try? store.setStatus("incomplete", for: practiceID, issue: item.issue)
            }
        }
        return accepted
    }

    private func route(for item: JournalItem, sessionID: UUID) throws -> String {
        let fields = item.id.split(separator: "/").map(String.init)
        let prefix = "sessions/\(sessionID.uuidString)"
        switch (item.kind, fields.count) {
        case ("audio", 2):
            guard UUID(uuidString: fields[1]) != nil else { throw BackendFailure.invalidResponse }
            return "\(prefix)/learner-turns/\(fields[1])/audio"
        case ("learnerTranscript", 2):
            guard UUID(uuidString: fields[1]) != nil else { throw BackendFailure.invalidResponse }
            return "\(prefix)/learner-turns/\(fields[1])/transcript"
        case ("agentTranscript", 3):
            guard fields[1].range(of: "^[A-Za-z0-9_-]{1,200}$", options: .regularExpression) != nil,
                  Int(fields[2]) != nil else { throw BackendFailure.invalidResponse }
            return "\(prefix)/agent-items/\(fields[1])/transcripts/\(fields[2])"
        default: throw BackendFailure.invalidResponse
        }
    }
}
