import Foundation

@MainActor struct CoachingClient {
    let baseURL: URL
    let session: URLSession
    let uploader: UploadJournalClient
    let account: AccountSession?
    let maximumPolls: Int
    let sleep: (UInt64) async -> Void

    init(baseURL: URL? = nil, session: URLSession = .shared, account: AccountSession? = nil, maximumPolls: Int = 3,
         sleep: @escaping (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }) {
        let configured = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String
        let url = baseURL ?? URL(string: configured ?? "") ?? URL(string: "http://127.0.0.1:8000")!
        self.baseURL = url
        self.session = session
        self.uploader = UploadJournalClient(baseURL: url, session: session, account: account)
        self.account = account
        self.maximumPolls = maximumPolls
        self.sleep = sleep
    }

    func finish(practiceID: UUID, store: PracticeStore) async -> String {
        guard let practice = store.practices.first(where: { $0.id == practiceID }) else { return "Practice unavailable." }
        let lease = try? account?.lease()
        guard valid(practice, store: store, lease: lease) else { return "Sign in to retry this practice." }
        _ = await uploader.retry(practiceID: practiceID, store: store)
        guard valid(practice, store: store, lease: lease) else { return "Account changed. Saved work was kept on this device." }
        if store.journal.contains(where: { $0.practiceID == practiceID && $0.receipt == "rejected" }) {
            let issue = "A recording could not be processed. Retrying cannot repair it. Start a new practice."
            try? store.setStatus("incomplete", for: practiceID, issue: issue)
            return issue
        }
        if store.journal.contains(where: { $0.practiceID == practiceID && $0.receipt == "pending" }),
           !store.journal.contains(where: { $0.practiceID == practiceID && $0.issue?.contains("conflicts") == true }) {
            return "Some uploads are still pending. Retry saving before requesting feedback."
        }
        do {
            let manifest = try store.manifest(for: practiceID)
            let path = "sessions/\(practice.sessionID.uuidString)"
            let (statusData, _) = try await request("PUT", path: "\(path)/upload-manifest", body: manifest, expected: lease)
            guard valid(practice, store: store, lease: lease) else { return "Account changed. Saved work was kept on this device." }
            let status = try JSONDecoder().decode(DataStatus.self, from: statusData)
            let conflicted = store.journal.contains { $0.practiceID == practiceID && $0.issue?.contains("conflicts") == true }
            if conflicted {
                try? store.setStatus("incomplete", for: practiceID, issue: "Saved content conflicts with the server. Local bytes were preserved.")
                return "Saved content conflicts with the server. Review this practice in History."
            }
            guard status.readyForEvaluation && status.missing.isEmpty && status.unexpected.isEmpty else {
                try? store.setStatus("incomplete", for: practiceID, issue: "Saved practice has missing or unexpected data. Retry saved work when connected.")
                return "Saved practice is incomplete. Retry from History."
            }
            return await evaluate(practiceID: practiceID, store: store, explicitRetry: true)
        } catch {
            guard valid(practice, store: store, lease: lease) else { return "Account changed. Saved work was kept on this device." }
            try? store.setStatus("incomplete", for: practiceID, issue: "Could not confirm saved practice data. Retry when connected.")
            return "Could not confirm saved data. Retry from History."
        }
    }

    func evaluate(practiceID: UUID, store: PracticeStore, explicitRetry: Bool) async -> String {
        guard let practice = store.practices.first(where: { $0.id == practiceID }) else { return "Practice unavailable." }
        let lease = try? account?.lease()
        guard valid(practice, store: store, lease: lease) else { return "Sign in to assess this practice." }
        let path = "sessions/\(practice.sessionID.uuidString)/evaluation"
        do {
            for attempt in 0...maximumPolls {
                let (data, response) = try await request(explicitRetry ? "POST" : "GET", path: path, expected: lease)
                guard valid(practice, store: store, lease: lease) else { return "Account changed. Saved work was kept on this device." }
                let decoded = try JSONDecoder().decode(CoachingResponse.self, from: data)
                if decoded.validCompleted {
                    try store.saveReport(data, practiceID: practiceID)
                    return "Coaching report saved for offline reading."
                }
                guard response.statusCode == 202 || decoded.status == "waiting" || decoded.status == "running" else {
                    throw BackendFailure.invalidResponse
                }
                try? store.setStatus("evaluating", for: practiceID)
                if attempt == maximumPolls { return "Feedback is processing. Open History to check again." }
                let seconds = min(60, max(1, Int(response.value(forHTTPHeaderField: "Retry-After") ?? "5") ?? 5))
                await sleep(UInt64(seconds) * 1_000_000_000)
            }
            return "Feedback is processing. Open History to check again."
        } catch {
            guard valid(practice, store: store, lease: lease) else { return "Account changed. Saved work was kept on this device." }
            try? store.setStatus("evaluationFailed", for: practiceID, issue: "Feedback unavailable. Retry assessment when connected.")
            return "Feedback unavailable. Retry assessment from History."
        }
    }

    func refresh(practiceID: UUID, store: PracticeStore) async -> String {
        guard let practice = store.practices.first(where: { $0.id == practiceID }) else { return "Practice unavailable." }
        let lease = try? account?.lease()
        guard valid(practice, store: store, lease: lease) else { return "Sign in to refresh this practice." }
        do {
            let (data, _) = try await request("GET", path: "sessions/\(practice.sessionID.uuidString)/evaluation", expected: lease)
            guard valid(practice, store: store, lease: lease) else { return "Account changed. Saved report was kept." }
            let decoded = try JSONDecoder().decode(CoachingResponse.self, from: data)
            guard decoded.validCompleted else { throw BackendFailure.invalidResponse }
            try store.saveReport(data, practiceID: practiceID)
            return "Coaching report refreshed."
        } catch { return "Could not refresh. Your saved report is still available." }
    }

    private func valid(_ practice: PracticeRecord, store: PracticeStore, lease: (String, UUID)?) -> Bool {
        guard store.accountID == practice.owner, store.practices.contains(where: { $0.id == practice.id }) else { return false }
        guard let account else { return true }
        guard let lease else { return false }
        return account.isCurrent(lease.0, generation: lease.1)
    }

    private func request(_ method: String, path: String, body: Data? = nil,
                         expected: (String, UUID)? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 90
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data: Data
        let response: HTTPURLResponse
        if let account { (data, response) = try await account.send(request, using: session, expected: expected) }
        else {
            let (received, raw) = try await session.data(for: request)
            guard let valid = raw as? HTTPURLResponse else { throw BackendFailure.invalidResponse }
            data = received; response = valid
        }
        guard [200, 201, 202].contains(response.statusCode) else { throw BackendFailure.status(response.statusCode) }
        return (data, response)
    }
}
