import Combine
import AVFoundation
import Foundation

@MainActor
final class CallCoordinator: ObservableObject {
    @Published private(set) var phase: CallPhase = .idle {
        didSet { DiagnosticLog.shared.record("call.phase", fields: ["phase": String(describing: phase), "attempt": attempt.uuidString]) }
    }
    @Published private(set) var message: String?
    @Published private(set) var transcripts: [String] = []
    @Published private(set) var parts: [ConversationPart] = []
    @Published private(set) var speakerEnabled = true

    private let backend: BackendServing
    private let permission: MicrophonePermissionProviding
    private let transport: RealtimeTransporting
    var supportsAudioFeedback: Bool { recorder != nil }

    private let recorder: TurnRecording?
    private let store: PracticeStore?
    private let coaching: CoachingClient?
    private let clearTimeoutNanoseconds: UInt64
    private let heartbeatNanoseconds: UInt64
    private let maxTurnNanoseconds: UInt64
    private var attempt = UUID()
    private var sessionID: UUID?
    private var practiceID: UUID?
    private var practiceStartedAt: Date?
    private var clearContinuation: CheckedContinuation<Bool, Never>?
    private var turnID: UUID?
    private var committedItemID: String?
    private var lastRecordingURL: URL?
    private var heartbeatTask: Task<Void, Never>?
    private var recordingLimitTask: Task<Void, Never>?
    private var finishTurnTask: Task<Void, Never>?
    private var transportNeedsClose = false
    private var agentParts = Set<String>()
    private var seenLearnerItems = Set<String>()

    init(backend: BackendServing, permission: MicrophonePermissionProviding,
         transport: RealtimeTransporting, recorder: TurnRecording?,
         store: PracticeStore? = nil,
         coaching: CoachingClient? = nil,
         clearTimeoutNanoseconds: UInt64 = 5_000_000_000,
         heartbeatNanoseconds: UInt64 = 30_000_000_000,
         maxTurnNanoseconds: UInt64 = 300_000_000_000) {
        self.backend = backend
        self.permission = permission
        self.transport = transport
        self.recorder = recorder
        self.store = store
        self.coaching = coaching
        self.clearTimeoutNanoseconds = clearTimeoutNanoseconds
        self.heartbeatNanoseconds = heartbeatNanoseconds
        self.maxTurnNanoseconds = maxTurnNanoseconds
    }

    deinit {
        heartbeatTask?.cancel()
        recordingLimitTask?.cancel()
        finishTurnTask?.cancel()
        let transport = transport
        let recorder = recorder
        let backend = backend
        let abandonedSession = sessionID
        Task { @MainActor in
            transport.onEvent = nil
            transport.close()
            recorder?.cancel()
            if let abandonedSession { try? await backend.endSession(abandonedSession) }
        }
    }

    func start(preferences: SessionPreferences) async {
        guard phase == .idle || phase == .failed || phase == .completed else { return }
        let preferences = preferences.normalized
        if let error = preferences.validationMessage { message = error; return }
        let current = UUID()
        attempt = current
        DiagnosticLog.shared.record("call.start", fields: ["attempt": current.uuidString])
        phase = .requestingPermission
        message = nil
        speakerEnabled = true
        transcripts = []
        parts = []
        agentParts = []
        seenLearnerItems = []
        let allowed = await permission.request()
        DiagnosticLog.shared.record("audio.permission", fields: ["allowed": String(allowed)])
        guard attempt == current else { return }
        guard allowed else { fail("Allow microphone access in Settings to practice speaking."); return }
        phase = .connecting

        var stage = "Session creation"
        do {
            let result = try await backend.createSession(preferences, key: current)
            guard attempt == current else {
                return
            }
            DiagnosticLog.shared.record("call.session_created", fields: ["attempt": current.uuidString, "realtime_present": String(result.realtime != nil)])
            sessionID = result.session.id
            stage = "Saving practice"
            if let store {
                try store.create(id: current, sessionID: result.session.id, key: current, preferences: preferences)
                practiceID = current
                practiceStartedAt = Date()
            }
            startHeartbeat(for: current, sessionID: result.session.id)
            DiagnosticLog.shared.record("call.credential", fields: ["valid": String(result.realtime?.clientCredential.isValid ?? false)])
            guard let realtime = result.realtime, realtime.clientCredential.isValid else {
                throw CallFailure.credentialUnavailable
            }
            transport.onEvent = { [weak self] event in
                Task { @MainActor [weak self] in
                    guard let self, self.attempt == current else { return }
                    self.handle(event)
                }
            }
            stage = "Realtime connection"
            transportNeedsClose = true
            try await transport.connect(url: realtime.webrtcURL, credential: realtime.clientCredential.value)
            guard attempt == current else { return }
            stage = "Realtime setup"
            try transport.send([
                "type": "session.update",
                "session": ["type": "realtime", "audio": ["input": [
                    "transcription": ["model": "whisper-1"], "turn_detection": NSNull()
                ]]]
            ])
            // Keep capture enabled for the connected session, as in the
            // OpenAI PTT demo. Clear/commit events define individual turns.
            try transport.startInput()
            try transport.send(["type": "response.create"])
            // The channel is open, but manual-turn setup is confirmed by session.updated.
            if phase == .connecting { message = "Your speaking partner is getting ready…" }
        } catch {
            guard attempt == current else { return }
            DiagnosticLog.shared.failure("call.connect_failure", error: error, fields: ["stage": stage, "attempt": current.uuidString])
            await stopCurrent()
            if error is CallFailure {
                fail("We couldn’t start your conversation. Please try a new session.")
            } else if let backendError = error as? BackendFailure, backendError == .status(429) {
                fail("This account has started too many requests. Wait a minute, then try again.")
            } else if let transportError = error as? RealtimeFailure, transportError == .dependencyUnavailable {
                fail("Speaking practice isn’t available in this version of the app. Please update the app.")
            } else if case BackendFailure.status = error {
                fail("We couldn’t start your conversation. Please try again.")
            } else if case RealtimeFailure.providerStatus = error {
                fail("Your speaking partner isn’t available right now. Please try again.")
            } else if case RealtimeFailure.connectionTimedOut = error {
                fail("Your conversation took too long to start. Check your internet and try again.")
            } else if error is DecodingError {
                fail("We couldn’t get your conversation ready. Please update the app or contact support.")
            } else {
                fail("We couldn’t start your conversation. Check your internet and try again.")
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
            if let practiceID {
                try store?.savePart(id: id.uuidString, practiceID: practiceID, speaker: "You", text: "", offsetMilliseconds: offset())
            }
            try await recorder?.start(turnID: id)
            guard attempt == current else { return }
            turnID = id
            committedItemID = nil
            phase = .recording
            message = nil
            recordingLimitTask?.cancel()
            let limit = maxTurnNanoseconds
            recordingLimitTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: limit)
                guard let self, !Task.isCancelled, self.attempt == current,
                      self.phase == .recording else { return }
                await self.finishTurn()
                if self.phase == .waitingForTranscript {
                    self.message = "Turn ended after five minutes to keep the recording within the upload limit."
                }
            }
        } catch {
            guard attempt == current else { return }
            await stopCurrent()
            fail("Could not record this turn. Start a new session.")
        }
    }

    func finishTurn() async {
        if phase == .finalizingTurn { await finishTurnTask?.value; return }
        guard phase == .recording else { return }
        phase = .finalizingTurn
        let current = attempt
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.finishRecordedTurn(for: current)
        }
        finishTurnTask = task
        await task.value
        if attempt == current { finishTurnTask = nil }
    }

    private func finishRecordedTurn(for current: UUID) async {
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
        do {
            let url = try await recorder?.stop()
            guard attempt == current else {
                if let url { Task.detached { try? FileManager.default.removeItem(at: url) } }
                return
            }
            lastRecordingURL = url
            if let practiceID, let turnID, let lastRecordingURL {
                try await store?.queueRecordedAudio(turnID: turnID, practiceID: practiceID, source: lastRecordingURL)
                guard attempt == current else { return }
                self.lastRecordingURL = nil
            }
            phase = .waitingForTranscript
            try transport.send(["type": "input_audio_buffer.commit"])
            try transport.send(["type": "response.create"])
        } catch RecordingFailure.noAudio {
            guard attempt == current else { return }
            DiagnosticLog.shared.record("audio.turn_no_signal")
            do {
                if let practiceID, let turnID { try store?.discardUncapturedTurn(turnID, practiceID: practiceID) }
                turnID = nil
                committedItemID = nil
                phase = .ready
                message = "No microphone audio was captured. Check your microphone and tap to try again."
            } catch {
                await stopCurrent()
                fail("Could not save this practice on your device.")
            }
        } catch {
            guard attempt == current else { return }
            DiagnosticLog.shared.failure("audio.finish_turn_failure", error: error)
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

    func accountDidChange() {
        attempt = UUID()
        resolveClear(false)
        heartbeatTask?.cancel()
        heartbeatTask = nil
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
        transport.setInputEnabled(false)
        transport.onEvent = nil
        if transportNeedsClose { transportNeedsClose = false; transport.close() }
        recorder?.cancel()
        if let url = lastRecordingURL { try? FileManager.default.removeItem(at: url) }
        if let practiceID { try? store?.setStatus("incomplete", for: practiceID, issue: "Account changed during practice.") }
        sessionID = nil; practiceID = nil; practiceStartedAt = nil
        turnID = nil; committedItemID = nil; lastRecordingURL = nil
        transcripts = []; parts = []; phase = .idle; message = nil
    }

    func endAndGetFeedback() async {
        guard recorder != nil else {
            await disconnect()
            message = "Conversation saved. Audio feedback is unavailable until turn recording is connected."
            return
        }

        guard [.connecting, .ready, .preparingTurn, .recording, .finalizingTurn, .waitingForTranscript].contains(phase) else { return }
        let current = attempt
        if phase == .recording || phase == .finalizingTurn { await finishTurn() }
        if phase == .waitingForTranscript {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        guard attempt == current else { return }
        guard phase != .failed else { return }
        phase = .finishing
        attempt = UUID()
        let finishing = attempt
        await stopCurrent(status: "ended")
        guard attempt == finishing else { return }
        if let store, let coaching, store.practices.first(where: { $0.id == current })?.status == "ended" {
            phase = .evaluating
            message = await coaching.finish(practiceID: current, store: store)
            guard attempt == finishing else { return }
        } else {
            message = store?.practices.first(where: { $0.id == current })?.status == "incomplete"
                ? "Practice saved with missing data. Open History to review and retry."
                : "Practice saved on this device. Feedback is pending."
        }
        phase = .completed
    }

    func audioRouteChanged(_ raw: UInt?) async {
        let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        // WebRTC reconfigures I/O ports during setRemoteDescription. This does not
        // mean the route was lost, and cancelling here aborts a valid connection.
        let expected = reason == .override || reason == .categoryChange || reason == .routeConfigurationChange
            || (reason == .newDeviceAvailable && phase == .connecting)
        DiagnosticLog.shared.record("audio.route_change", fields: [
            "reason": String(raw ?? 0), "action": expected ? "continue" : "stop"
        ])
        guard !expected else { return }
        await stopForInterruption("Audio route changed. Start a new practice.")
    }

    func stopForInterruption(_ reason: String) async {
        DiagnosticLog.shared.record("call.interruption", fields: ["phase": String(describing: phase)])
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
        let interval = heartbeatNanoseconds
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: interval) } catch { return }
                guard let self, !Task.isCancelled, self.attempt == current else { return }
                try? await self.backend.heartbeat(sessionID)
            }
        }
    }

    private func handle(_ event: RealtimeEvent) {
        if ["session.created", "session.updated", "error", "transport.closed", "response.created", "response.done", "input_audio_buffer.cleared", "input_audio_buffer.committed"].contains(event.type) {
            var fields = ["type": event.type, "attempt": attempt.uuidString]
            if let code = event.errorCode { fields["provider_error_code"] = code }
            DiagnosticLog.shared.record("call.event", fields: fields)
        }
        switch event.type {
        case "session.updated":
            if event.turnDetectionDisabled == true && phase == .connecting {
                phase = .ready
                message = "Tap the microphone whenever you’re ready to speak."
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
                if let practiceID {
                    do {
                        let start = store?.parts.first { $0.id == turnID.uuidString && $0.practiceID == practiceID }?.offsetMilliseconds ?? 0
                        let payload: [String: Any] = ["text": text, "start_ms": start,
                                                      "end_ms": max(start + 1, offset()), "provider_item_id": committedItemID]
                        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                        try store?.queuePayload(id: "transcript/\(turnID.uuidString)", practiceID: practiceID,
                                                kind: "learnerTranscript", bytes: bytes, contentType: "application/json")
                        try store?.savePart(id: turnID.uuidString, practiceID: practiceID, speaker: "You", text: text, offsetMilliseconds: start)
                    }
                    catch {
                        try? store?.setStatus("incomplete", for: practiceID, issue: "Transcript could not be saved.")
                        message = "Transcript could not be saved on this device."
                    }
                }
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
                if let practiceID {
                    do {
                        let payload: [String: Any] = ["text": text, "response_id": event.responseID ?? "",
                                                      "playback_status": "unknown"]
                        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                        try store?.queuePayload(id: "agent/\(key)", practiceID: practiceID,
                                                kind: "agentTranscript", bytes: bytes, contentType: "application/json")
                        try store?.savePart(id: key, practiceID: practiceID, speaker: "Agent", text: text, offsetMilliseconds: offset())
                    }
                    catch {
                        try? store?.setStatus("incomplete", for: practiceID, issue: "Transcript could not be saved.")
                        message = "Transcript could not be saved on this device."
                    }
                }
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

    private func stopCurrent(status: String = "incomplete") async {
        resolveClear(false)
        heartbeatTask?.cancel()
        heartbeatTask = nil
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
        transport.setInputEnabled(false)
        transport.onEvent = nil
        if transportNeedsClose { transportNeedsClose = false; transport.close() }
        recorder?.cancel()
        if let url = lastRecordingURL { try? FileManager.default.removeItem(at: url) }
        lastRecordingURL = nil
        turnID = nil
        committedItemID = nil
        if let id = sessionID {
            sessionID = nil
            do {
                try await backend.endSession(id)
                if let practiceID {
                    let unfinished = store?.parts.contains { $0.practiceID == practiceID && $0.speaker == "You" && $0.text.isEmpty } ?? false
                    if unfinished {
                        try? store?.setStatus("incomplete", for: practiceID, issue: "A learner turn has no final transcript.")
                    } else {
                        try? store?.setStatus(status, for: practiceID)
                    }
                }
            } catch {
                if let practiceID { try? store?.setStatus("incomplete", for: practiceID, issue: "Could not confirm the session ended.") }
            }
        }
        practiceID = nil
        practiceStartedAt = nil
    }

    private func offset() -> Int {
        Int((Date().timeIntervalSince(practiceStartedAt ?? Date()) * 1000).rounded())
    }

    private func fail(_ text: String) {
        DiagnosticLog.shared.record("call.failed", fields: ["attempt": attempt.uuidString])
        phase = .failed
        message = text
    }
}

private enum CallFailure: Error { case credentialUnavailable }
