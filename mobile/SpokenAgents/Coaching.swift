import Foundation

struct ManifestAgent: Codable, Equatable {
    let itemID: String
    let contentIndex: Int
    enum CodingKeys: String, CodingKey { case itemID = "item_id", contentIndex = "content_index" }
}

struct UploadManifest: Codable {
    let audioTurnIDs: [String]
    let transcriptTurnIDs: [String]
    let agentTranscripts: [ManifestAgent]
    enum CodingKeys: String, CodingKey {
        case audioTurnIDs = "audio_turn_ids", transcriptTurnIDs = "transcript_turn_ids", agentTranscripts = "agent_transcripts"
    }
}

struct UploadInventory: Decodable {
    let audioTurnIDs: [String]
    let transcriptTurnIDs: [String]
    let agentTranscripts: [ManifestAgent]
    enum CodingKeys: String, CodingKey {
        case audioTurnIDs = "audio_turn_ids", transcriptTurnIDs = "transcript_turn_ids", agentTranscripts = "agent_transcripts"
    }
    var isEmpty: Bool { audioTurnIDs.isEmpty && transcriptTurnIDs.isEmpty && agentTranscripts.isEmpty }
}

struct DataStatus: Decodable {
    let readyForEvaluation: Bool
    let missing: UploadInventory
    let unexpected: UploadInventory
    enum CodingKeys: String, CodingKey { case readyForEvaluation = "ready_for_evaluation", missing, unexpected }
}

struct CoachingCategory: Decodable {
    let score: Int?
    let feedback: String
}

struct CoachingCorrection: Decodable, Identifiable {
    let turnID: String
    let original: String
    let improved: String
    let explanation: String
    var id: String { "\(turnID)/\(original)/\(improved)" }
    enum CodingKeys: String, CodingKey { case turnID = "turn_id", original, improved, explanation }
}

struct CoachingResult: Decodable {
    let summary: String
    let grammar: CoachingCategory
    let vocabulary: CoachingCategory
    let coherence: CoachingCategory
    let strengths: [String]
    let nextSteps: [String]
    let corrections: [CoachingCorrection]
    enum CodingKeys: String, CodingKey {
        case summary, grammar, vocabulary, coherence, strengths, nextSteps = "next_steps", corrections
    }
}

struct SpeechSummary: Decodable {
    let assessedTurns: Int
    let totalTurns: Int
    let averagePronunciation: Int?
    let averageSpokenFluency: Int?
    let averageRhythmAndIntonation: Int?
    enum CodingKeys: String, CodingKey {
        case assessedTurns = "assessed_turns", totalTurns = "total_turns"
        case averagePronunciation = "average_pronunciation", averageSpokenFluency = "average_spoken_fluency"
        case averageRhythmAndIntonation = "average_rhythm_and_intonation"
    }
}

struct CoachingResponse: Decodable {
    let status: String
    let result: CoachingResult?
    let speechSummary: SpeechSummary?
    let notAssessed: [String]
    enum CodingKeys: String, CodingKey { case status, result, speechSummary = "speech_summary", notAssessed = "not_assessed" }
    var validCompleted: Bool {
        guard status == "completed", let result else { return false }
        let categories = [result.grammar, result.vocabulary, result.coherence]
        return !result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !result.strengths.isEmpty && !result.nextSteps.isEmpty &&
            categories.allSatisfy { $0.score.map { (1...5).contains($0) } ?? true } &&
            categories.allSatisfy { !$0.feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } &&
            result.corrections.allSatisfy {
                !$0.original.isEmpty && !$0.improved.isEmpty && !$0.explanation.isEmpty
            }
    }
}

@MainActor struct CoachingClient {
    let baseURL: URL
    let session: URLSession
    let uploader: UploadJournalClient
    let maximumPolls: Int
    let sleep: (UInt64) async -> Void

    init(baseURL: URL? = nil, session: URLSession = .shared, maximumPolls: Int = 3,
         sleep: @escaping (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }) {
        let configured = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String
        let url = baseURL ?? URL(string: configured ?? "") ?? URL(string: "http://127.0.0.1:8000")!
        self.baseURL = url
        self.session = session
        self.uploader = UploadJournalClient(baseURL: url, session: session)
        self.maximumPolls = maximumPolls
        self.sleep = sleep
    }

    func finish(practiceID: UUID, store: PracticeStore) async -> String {
        guard let practice = store.practices.first(where: { $0.id == practiceID }) else { return "Practice unavailable." }
        _ = await uploader.retry(practiceID: practiceID, store: store)
        do {
            let manifest = try store.manifest(for: practiceID)
            let path = "sessions/\(practice.sessionID.uuidString)"
            let (statusData, _) = try await request("PUT", path: "\(path)/upload-manifest", body: manifest)
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
            try? store.setStatus("incomplete", for: practiceID, issue: "Could not confirm saved practice data. Retry when connected.")
            return "Could not confirm saved data. Retry from History."
        }
    }

    func evaluate(practiceID: UUID, store: PracticeStore, explicitRetry: Bool) async -> String {
        guard let practice = store.practices.first(where: { $0.id == practiceID }) else { return "Practice unavailable." }
        let path = "sessions/\(practice.sessionID.uuidString)/evaluation"
        do {
            for attempt in 0...maximumPolls {
                let (data, response) = try await request(explicitRetry ? "POST" : "GET", path: path)
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
            try? store.setStatus("evaluationFailed", for: practiceID, issue: "Feedback unavailable. Retry assessment when connected.")
            return "Feedback unavailable. Retry assessment from History."
        }
    }

    func refresh(practiceID: UUID, store: PracticeStore) async -> String {
        guard let practice = store.practices.first(where: { $0.id == practiceID }) else { return "Practice unavailable." }
        do {
            let (data, _) = try await request("GET", path: "sessions/\(practice.sessionID.uuidString)/evaluation")
            let decoded = try JSONDecoder().decode(CoachingResponse.self, from: data)
            guard decoded.validCompleted else { throw BackendFailure.invalidResponse }
            try store.saveReport(data, practiceID: practiceID)
            return "Coaching report refreshed."
        } catch { return "Could not refresh. Your saved report is still available." }
    }

    private func request(_ method: String, path: String, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 90
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, raw) = try await session.data(for: request)
        guard let response = raw as? HTTPURLResponse else { throw BackendFailure.invalidResponse }
        guard [200, 201, 202].contains(response.statusCode) else { throw BackendFailure.status(response.statusCode) }
        return (data, response)
    }
}
