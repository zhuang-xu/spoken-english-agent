import Combine
import AVFoundation
import Foundation

enum CallPhase: Equatable {
    case idle, requestingPermission, connecting, ready, preparingTurn, recording, waitingForTranscript, finishing, evaluating, completed, failed

    var title: String {
        switch self {
        case .idle: "Ready to connect"
        case .requestingPermission: "Waiting for microphone permission"
        case .connecting: "Connecting audio"
        case .ready: "Connected"
        case .preparingTurn: "Preparing microphone"
        case .recording: "Recording your turn"
        case .waitingForTranscript: "Waiting for transcript"
        case .finishing: "Ending practice"
        case .evaluating: "Preparing feedback"
        case .completed: "Practice ended"
        case .failed: "Connection failed"
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

@MainActor
final class CallCoordinator: ObservableObject {
    @Published private(set) var phase: CallPhase = .idle
    @Published private(set) var message: String?
    @Published private(set) var transcripts: [String] = []
    @Published private(set) var parts: [ConversationPart] = []
    @Published private(set) var speakerEnabled = true

    private let backend: BackendServing
    private let permission: MicrophonePermissionProviding
    private let transport: RealtimeTransporting
    private let recorder: TurnRecording
    private let clearTimeoutNanoseconds: UInt64
    private let heartbeatNanoseconds: UInt64
    private var attempt = UUID()
    private var sessionID: UUID?
    private var clearContinuation: CheckedContinuation<Bool, Never>?
    private var turnID: UUID?
    private var committedItemID: String?
    private var lastRecordingURL: URL?
    private var heartbeatTask: Task<Void, Never>?
    private var transportNeedsClose = false
    private var agentParts = Set<String>()
    private var seenLearnerItems = Set<String>()

    init(backend: BackendServing, permission: MicrophonePermissionProviding,
         transport: RealtimeTransporting, recorder: TurnRecording,
         clearTimeoutNanoseconds: UInt64 = 5_000_000_000,
         heartbeatNanoseconds: UInt64 = 30_000_000_000) {
        self.backend = backend
        self.permission = permission
        self.transport = transport
        self.recorder = recorder
        self.clearTimeoutNanoseconds = clearTimeoutNanoseconds
        self.heartbeatNanoseconds = heartbeatNanoseconds
    }

    func start(preferences: SessionPreferences) async {
        guard phase == .idle || phase == .failed || phase == .completed else { return }
        let preferences = preferences.normalized
        if let error = preferences.validationMessage { message = error; return }
        let current = UUID()
        attempt = current
        phase = .requestingPermission
        message = nil
        transcripts = []
        parts = []
        agentParts = []
        seenLearnerItems = []
        let allowed = await permission.request()
        guard attempt == current else { return }
        guard allowed else { fail("Allow microphone access in Settings to practice speaking."); return }
        phase = .connecting

        do {
            let result = try await backend.createSession(preferences, key: current)
            guard attempt == current else {
                try? await backend.endSession(result.session.id)
                return
            }
            sessionID = result.session.id
            startHeartbeat(for: current, sessionID: result.session.id)
            guard let realtime = result.realtime, realtime.clientCredential.isValid else {
                throw CallFailure.credentialUnavailable
            }
            transport.onEvent = { [weak self] event in
                Task { @MainActor [weak self] in
                    guard let self, self.attempt == current else { return }
                    self.handle(event)
                }
            }
            transportNeedsClose = true
            try await transport.connect(url: realtime.webrtcURL, credential: realtime.clientCredential.value)
            guard attempt == current else { return }
            try transport.send([
                "type": "session.update",
                "session": ["type": "realtime", "audio": ["input": [
                    "transcription": ["model": "whisper-1"], "turn_detection": NSNull()
                ]]]
            ])
            try transport.send(["type": "response.create"])
            // The channel is open, but manual-turn setup is confirmed by session.updated.
            if phase == .connecting { message = "Connected. Preparing manual turns…" }
        } catch {
            guard attempt == current else { return }
            await stopCurrent()
            if error is CallFailure {
                fail("Connection credential unavailable. Start a new session.")
            } else if let transportError = error as? RealtimeFailure, transportError == .dependencyUnavailable {
                fail("This build does not include the WebRTC binary. Use the native project variant.")
            } else {
                fail("Could not connect. Check your network and service, then try again.")
            }
        }
    }

    func startTurn() async {
        guard phase == .ready else { return }
        phase = .preparingTurn
        let current = attempt
        do {
            let cleared = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                clearContinuation = continuation
                do { try transport.send(["type": "input_audio_buffer.clear"]) }
                catch { resolveClear(false) }
                let timeout = clearTimeoutNanoseconds
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: timeout)
                    guard let self, self.attempt == current else { return }
                    self.resolveClear(false)
                }
            }
            guard attempt == current else { return }
            guard cleared else { phase = .ready; message = "Could not prepare the turn. Try again."; return }
            let id = UUID()
            try recorder.start(turnID: id)
            turnID = id
            committedItemID = nil
            transport.setInputEnabled(true)
            phase = .recording
            message = nil
        } catch {
            guard attempt == current else { return }
            await stopCurrent()
            fail("Could not record this turn. Start a new session.")
        }
    }

    func finishTurn() async {
        guard phase == .recording else { return }
        transport.setInputEnabled(false)
        do {
            lastRecordingURL = try recorder.stop()
            phase = .waitingForTranscript
            try transport.send(["type": "input_audio_buffer.commit"])
            try transport.send(["type": "response.create"])
        } catch {
            await stopCurrent()
            fail("Could not finish this turn. Start a new session.")
        }
    }

    func disconnect() async {
        attempt = UUID()
        await stopCurrent()
        phase = .idle
        message = nil
    }

    func endAndGetFeedback() async {
        guard [.connecting, .ready, .preparingTurn, .recording, .waitingForTranscript].contains(phase) else { return }
        let current = attempt
        if phase == .recording { await finishTurn() }
        if phase == .waitingForTranscript {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        guard attempt == current else { return }
        guard phase != .failed else { return }
        phase = .finishing
        attempt = UUID()
        await stopCurrent()
        phase = .completed
        message = "Practice ended. Feedback saving is planned for Phase 4."
    }

    func stopForInterruption(_ reason: String) async {
        guard sessionID != nil || transportNeedsClose || [.requestingPermission, .connecting].contains(phase) else { return }
        attempt = UUID()
        await stopCurrent()
        fail(reason)
    }

    func toggleSpeaker() {
        guard transportNeedsClose else { return }
        do {
            try transport.setSpeakerEnabled(!speakerEnabled)
            speakerEnabled.toggle()
        } catch { message = "Could not change audio output." }
    }

    private func startHeartbeat(for current: UUID, sessionID: UUID) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: heartbeatNanoseconds)
                guard !Task.isCancelled, attempt == current else { return }
                try? await backend.heartbeat(sessionID)
            }
        }
    }

    private func handle(_ event: RealtimeEvent) {
        switch event.type {
        case "session.updated":
            if event.turnDetectionDisabled == true && phase == .connecting {
                phase = .ready
                message = "Connected. Use Start speaking for your turn."
            }
        case "input_audio_buffer.cleared":
            resolveClear(true)
        case "input_audio_buffer.committed":
            if phase == .waitingForTranscript && committedItemID == nil { committedItemID = event.itemID }
        case "conversation.item.input_audio_transcription.completed", "conversation.item.audio_transcription.completed":
            guard phase == .waitingForTranscript, let committedItemID,
                  committedItemID == event.itemID else { return }
            if let text = event.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
               let turnID, seenLearnerItems.insert(committedItemID).inserted {
                transcripts.append("You: \(text)")
                parts.append(ConversationPart(id: turnID.uuidString, speaker: "You", text: text, playback: .completed))
            }
            turnID = nil
            self.committedItemID = nil
            phase = .ready
        case "response.output_audio_transcript.done":
            guard let itemID = event.itemID, let index = event.contentIndex, index >= 0,
                  event.responseID != nil, let text = event.transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            let key = "\(itemID)/\(index)"
            if agentParts.insert(key).inserted {
                transcripts.append("Agent: \(text)")
                parts.append(ConversationPart(id: key, speaker: "Agent", text: text, playback: .unknown))
            }
        case "transport.closed", "error":
            let current = attempt
            Task {
                guard attempt == current else { return }
                await stopCurrent()
                guard attempt == current else { return }
                fail("Conversation ended. Start a new session.")
            }
        default:
            break
        }
    }

    private func resolveClear(_ result: Bool) {
        clearContinuation?.resume(returning: result)
        clearContinuation = nil
    }

    private func stopCurrent() async {
        resolveClear(false)
        heartbeatTask?.cancel()
        heartbeatTask = nil
        transport.setInputEnabled(false)
        transport.onEvent = nil
        if transportNeedsClose { transportNeedsClose = false; transport.close() }
        recorder.cancel()
        if let url = lastRecordingURL { try? FileManager.default.removeItem(at: url) }
        lastRecordingURL = nil
        turnID = nil
        committedItemID = nil
        if let id = sessionID {
            sessionID = nil
            try? await backend.endSession(id)
        }
    }

    private func fail(_ text: String) {
        phase = .failed
        message = text
    }
}

private enum CallFailure: Error { case credentialUnavailable }
