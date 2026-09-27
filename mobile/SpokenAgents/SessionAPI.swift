import Foundation

struct SessionPreferences: Encodable, Equatable {
    let speakingGoal: String
    let level: String
    let preferredTopic: String?
    let sessionDurationMinutes: Int

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

protocol BackendServing {
    func createSession(_ preferences: SessionPreferences, key: UUID) async throws -> SessionStart
    func endSession(_ id: UUID) async throws
}

struct HTTPBackendClient: BackendServing {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL? = nil, session: URLSession = .shared) {
        let configured = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String
        self.baseURL = baseURL ?? URL(string: configured ?? "") ?? URL(string: "http://127.0.0.1:8000")!
        self.session = session
    }

    func createSession(_ preferences: SessionPreferences, key: UUID) async throws -> SessionStart {
        var request = URLRequest(url: baseURL.appending(path: "sessions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key.uuidString, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONEncoder().encode(preferences)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw BackendFailure.invalidResponse }
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
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw BackendFailure.invalidResponse }
        guard response.statusCode == 200 else { throw BackendFailure.status(response.statusCode) }
    }
}
