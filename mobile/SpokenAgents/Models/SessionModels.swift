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
