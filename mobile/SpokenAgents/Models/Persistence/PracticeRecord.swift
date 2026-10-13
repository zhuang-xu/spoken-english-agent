import Foundation
import SwiftData

@Model final class PracticeRecord {
    @Attribute(.unique) var id: UUID
    var owner: String
    var sessionID: UUID
    var idempotencyKey: UUID
    var startedAt: Date
    var endedAt: Date?
    var updatedAt: Date
    var goal: String
    var level: String
    var topic: String?
    var durationMinutes: Int
    var status: String
    var issue: String?
    var reportData: Data?
    var manifestData: Data?

    init(id: UUID, owner: String, sessionID: UUID, key: UUID, preferences: SessionPreferences) {
        self.id = id; self.owner = owner; self.sessionID = sessionID; self.idempotencyKey = key
        self.startedAt = Date(); self.updatedAt = Date()
        self.goal = preferences.speakingGoal; self.level = preferences.level
        self.topic = preferences.preferredTopic; self.durationMinutes = preferences.sessionDurationMinutes
        self.status = "active"
    }
}

@Model final class SavedPart {
    var id: String
    var practiceID: UUID
    var speaker: String
    var text: String
    var playback: String
    var offsetMilliseconds: Int

    init(id: String, practiceID: UUID, speaker: String, text: String, playback: String, offsetMilliseconds: Int) {
        self.id = id; self.practiceID = practiceID; self.speaker = speaker; self.text = text
        self.playback = playback; self.offsetMilliseconds = offsetMilliseconds
    }
}

@Model final class JournalItem {
    var id: String
    var practiceID: UUID
    var kind: String
    var payload: Data?
    var fileName: String?
    var contentType: String
    var sha256: String
    var receipt: String
    var issue: String?

    init(id: String, practiceID: UUID, kind: String, payload: Data?, fileName: String?, contentType: String, sha256: String) {
        self.id = id; self.practiceID = practiceID; self.kind = kind; self.payload = payload
        self.fileName = fileName; self.contentType = contentType; self.sha256 = sha256
        self.receipt = "pending"
    }
}
