import Foundation

struct SessionPreferences: Encodable, Equatable {
    let speakingGoal: String
    let level: String
    let preferredTopic: String?
    let sessionDurationMinutes: Int

    var validationMessage: String? {
        let goal = speakingGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        let topic = preferredTopic?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !(2...500).contains(goal.count) { return "Speaking goal must be 2–500 characters." }
        if !["A1", "A2", "B1", "B2", "C1", "C2"].contains(level) { return "Choose a CEFR level." }
        if let topic, !(2...200).contains(topic.count) { return "Topic must be 2–200 characters." }
        if !(1...120).contains(sessionDurationMinutes) { return "Duration must be 1–120 minutes." }
        return nil
    }

    var normalized: Self {
        let topic = preferredTopic?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(speakingGoal: speakingGoal.trimmingCharacters(in: .whitespacesAndNewlines),
                    level: level, preferredTopic: topic?.isEmpty == true ? nil : topic,
                    sessionDurationMinutes: sessionDurationMinutes)
    }

    enum CodingKeys: String, CodingKey {
        case speakingGoal = "speaking_goal"
        case level
        case preferredTopic = "preferred_topic"
        case sessionDurationMinutes = "session_duration_minutes"
    }
}

struct SessionStart: Decodable, Equatable {
    struct Session: Decodable, Equatable {
        let id: UUID
        let status: String
    }

    struct Realtime: Decodable, Equatable {
        struct Credential: Decodable, Equatable {
            let value: String
            let expiresAt: String

            enum CodingKeys: String, CodingKey {
                case value
                case expiresAt = "expires_at"
            }

            var isValid: Bool {
                let parser = ISO8601DateFormatter()
                parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let expiry = parser.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt)
                return !value.isEmpty && (expiry ?? .distantPast) > Date()
            }
        }
        let webrtcURL: URL
        let clientCredential: Credential

        enum CodingKeys: String, CodingKey {
            case webrtcURL = "webrtc_url"
            case clientCredential = "client_credential"
        }
    }

    let session: Session
    let realtime: Realtime?
}

enum BackendFailure: Error, Equatable {
    case unavailable
    case status(Int)
    case invalidResponse
}

@MainActor protocol BackendServing {
    func createSession(_ preferences: SessionPreferences, key: UUID) async throws -> SessionStart
    func heartbeat(_ id: UUID) async throws
    func endSession(_ id: UUID) async throws
}

@MainActor struct HTTPBackendClient: BackendServing {
    private let baseURL: URL
    private let session: URLSession
    private let account: AccountSession?

    init(baseURL: URL? = nil, session: URLSession = .shared, account: AccountSession? = nil) {
        let configured = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String
        self.baseURL = baseURL ?? URL(string: configured ?? "") ?? URL(string: "http://127.0.0.1:8000")!
        self.session = session
        self.account = account
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let account { return try await account.send(request, using: session) }
        return try await DiagnosticHTTP.send(request, using: session)
    }

    func createSession(_ preferences: SessionPreferences, key: UUID) async throws -> SessionStart {
        var request = URLRequest(url: baseURL.appending(path: "sessions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key.uuidString, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONEncoder().encode(preferences)
        let (data, response) = try await send(request)
        guard response.statusCode == 201 || response.statusCode == 200 else {
            throw BackendFailure.status(response.statusCode)
        }
        return try JSONDecoder().decode(SessionStart.self, from: data)
    }

    func endSession(_ id: UUID) async throws {
        var request = URLRequest(url: baseURL.appending(path: "sessions/\(id.uuidString)/end"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, response) = try await send(request)
        guard response.statusCode == 200 else { throw BackendFailure.status(response.statusCode) }
    }

    func heartbeat(_ id: UUID) async throws {
        var request = URLRequest(url: baseURL.appending(path: "sessions/\(id.uuidString)/heartbeat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw BackendFailure.unavailable
        }
    }
}
