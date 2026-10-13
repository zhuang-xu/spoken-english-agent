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
