import Foundation

enum CallPhase: Equatable {
    case idle, requestingPermission, connecting, ready, preparingTurn, recording, finalizingTurn, waitingForTranscript, finishing, evaluating, completed, failed

    var title: String {
        switch self {
        case .idle: "Ready for a conversation"
        case .requestingPermission: "Allow your microphone to get started"
        case .connecting: "Getting your conversation ready"
        case .ready: "Ready to talk"
        case .preparingTurn: "Getting ready to listen"
        case .recording: "Listening to you"
        case .finalizingTurn: "Saving your turn"
        case .waitingForTranscript: "Preparing your reply"
        case .finishing: "Finishing your conversation"
        case .evaluating: "Preparing your feedback"
        case .completed: "Conversation complete"
        case .failed: "Let’s try again"
        }
    }
}

struct ConversationPart: Equatable, Identifiable {
    enum Playback: String { case completed, interrupted, unknown }
    let id: String
    let speaker: String
    let text: String
    let playback: Playback
}
