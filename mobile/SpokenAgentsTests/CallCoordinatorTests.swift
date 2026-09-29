import XCTest
@testable import SpokenAgents

@MainActor
final class CallCoordinatorTests: XCTestCase {
    private let preferences = SessionPreferences(speakingGoal: "Interview practice", level: "B1",
                                                 preferredTopic: nil, sessionDurationMinutes: 10)

    func testPermissionDenialDoesNotCreateSession() async {
        let backend = FakeBackend()
        let transport = FakeTransport()
        let call = CallCoordinator(backend: backend, permission: FakePermission(allowed: false),
                                   transport: transport, recorder: FakeRecorder())
        await call.start(preferences: preferences)
        XCTAssertEqual(call.phase, .failed)
        XCTAssertEqual(backend.createCount, 0)
        XCTAssertEqual(transport.connectCount, 0)
    }

    func testInvalidSetupNeverRequestsPermissionOrSession() async {
        let backend = FakeBackend()
        let call = CallCoordinator(backend: backend, permission: FakePermission(allowed: true),
                                   transport: FakeTransport(), recorder: FakeRecorder())
        await call.start(preferences: SessionPreferences(speakingGoal: " ", level: "B1",
                                                       preferredTopic: nil, sessionDurationMinutes: 10))
        XCTAssertEqual(call.phase, .idle)
        XCTAssertEqual(backend.createCount, 0)
    }

    func testAgentPartsAreIdentifiedAndDeduplicated() async {
        let transport = FakeTransport()
        let call = CallCoordinator(backend: FakeBackend(), permission: FakePermission(allowed: true),
                                   transport: transport, recorder: FakeRecorder())
        await call.start(preferences: preferences)
        let part = RealtimeEvent(type: "response.output_audio_transcript.done", itemID: "agent-1",
                                 transcript: "Hello", contentIndex: 0, responseID: "response-1")
        transport.emit(part)
        transport.emit(part)
        await Task.yield()
        XCTAssertEqual(call.parts.count, 1)
        XCTAssertEqual(call.parts.first?.id, "agent-1/0")
        XCTAssertEqual(call.parts.first?.playback, .unknown)
    }

    func testInterruptionEndsOnceAndRejectsLateEvents() async {
        let backend = FakeBackend()
        let transport = FakeTransport()
        let call = CallCoordinator(backend: backend, permission: FakePermission(allowed: true),
                                   transport: transport, recorder: FakeRecorder())
        await call.start(preferences: preferences)
        let callback = transport.onEvent
        await call.stopForInterruption("Interrupted")
        await call.stopForInterruption("Interrupted again")
        callback?(RealtimeEvent(type: "session.updated", turnDetectionDisabled: true))
        await Task.yield()
        XCTAssertEqual(call.phase, .failed)
        XCTAssertEqual(backend.endCount, 1)
        XCTAssertEqual(transport.closeCount, 1)
    }

    func testDisconnectDuringConnectionDoesNotCloseTwiceOrRevive() async {
        let backend = FakeBackend()
        let transport = FakeTransport()
        var finishConnect: CheckedContinuation<Void, Never>?
        transport.onConnect = { await withCheckedContinuation { finishConnect = $0 } }
        let call = CallCoordinator(backend: backend, permission: FakePermission(allowed: true),
                                   transport: transport, recorder: FakeRecorder())
        let starting = Task { await call.start(preferences: preferences) }
        while finishConnect == nil { await Task.yield() }
        await call.disconnect()
        finishConnect?.resume()
        await starting.value
        XCTAssertEqual(call.phase, .idle)
        XCTAssertEqual(backend.endCount, 1)
        XCTAssertEqual(transport.closeCount, 1)
    }

    func testHeartbeatStopsAfterDisconnect() async throws {
        let backend = FakeBackend()
        let transport = FakeTransport()
        let call = CallCoordinator(backend: backend, permission: FakePermission(allowed: true),
                                   transport: transport, recorder: FakeRecorder(), heartbeatNanoseconds: 1_000_000)
        await call.start(preferences: preferences)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertGreaterThan(backend.heartbeatCount, 0)
        await call.disconnect()
        let count = backend.heartbeatCount
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(backend.heartbeatCount, count)
    }

    func testConnectManualTurnAndCorrelateTranscript() async {
        let backend = FakeBackend()
        let transport = FakeTransport()
        let recorder = FakeRecorder()
        let call = CallCoordinator(backend: backend, permission: FakePermission(allowed: true),
                                   transport: transport, recorder: recorder)
        await call.start(preferences: preferences)
        XCTAssertEqual(call.phase, .connecting)
        XCTAssertEqual(backend.createCount, 1)
        XCTAssertNotNil(backend.key)
        XCTAssertEqual(transport.connectCount, 1)
        XCTAssertEqual(transport.sent.map { $0["type"] as? String }, ["session.update", "response.create"])

        transport.emit(RealtimeEvent(type: "session.updated", turnDetectionDisabled: true))
        await Task.yield()
        XCTAssertEqual(call.phase, .ready)
        let starting = Task { await call.startTurn() }
        await Task.yield()
        transport.emit(RealtimeEvent(type: "input_audio_buffer.cleared"))
        await starting.value
        XCTAssertEqual(call.phase, .recording)
        XCTAssertTrue(transport.inputEnabled)
        XCTAssertEqual(recorder.startCount, 1)

        await call.finishTurn()
        XCTAssertEqual(call.phase, .waitingForTranscript)
        XCTAssertFalse(transport.inputEnabled)
        XCTAssertEqual(transport.sent.suffix(2).compactMap { $0["type"] as? String },
                       ["input_audio_buffer.commit", "response.create"])
        transport.emit(RealtimeEvent(type: "conversation.item.input_audio_transcription.completed",
                                     itemID: "wrong", transcript: "Wrong turn"))
        await Task.yield()
        XCTAssertEqual(call.phase, .waitingForTranscript)
        transport.emit(RealtimeEvent(type: "input_audio_buffer.committed", itemID: "item-1"))
        transport.emit(RealtimeEvent(type: "conversation.item.input_audio_transcription.completed",
                                     itemID: "item-1", transcript: "My answer"))
        await Task.yield()
        XCTAssertEqual(call.phase, .ready)
        XCTAssertEqual(call.transcripts, ["You: My answer"])
        await call.disconnect()
        XCTAssertEqual(backend.endCount, 1)
        XCTAssertEqual(transport.closeCount, 1)
    }

    func testTransportFailureCleansUpSession() async {
        let backend = FakeBackend()
        let transport = FakeTransport()
        transport.connectError = RealtimeFailure.connectionTimedOut
        let call = CallCoordinator(backend: backend, permission: FakePermission(allowed: true),
                                   transport: transport, recorder: FakeRecorder())
        await call.start(preferences: preferences)
        XCTAssertEqual(call.phase, .failed)
        XCTAssertEqual(backend.endCount, 1)
        XCTAssertEqual(transport.closeCount, 1)
    }

    func testEventFromDisconnectedAttemptCannotReviveCall() async {
        let transport = FakeTransport()
        let call = CallCoordinator(backend: FakeBackend(), permission: FakePermission(allowed: true),
                                   transport: transport, recorder: FakeRecorder())
        await call.start(preferences: preferences)
        let oldCallback = transport.onEvent
        await call.disconnect()
        oldCallback?(RealtimeEvent(type: "session.updated", turnDetectionDisabled: true))
        await Task.yield()
        XCTAssertEqual(call.phase, .idle)
    }

    func testClearTimeoutLeavesInputMutedAndAllowsRetry() async {
        let transport = FakeTransport()
        let recorder = FakeRecorder()
        let call = CallCoordinator(backend: FakeBackend(), permission: FakePermission(allowed: true),
                                   transport: transport, recorder: recorder, clearTimeoutNanoseconds: 1_000_000)
        await call.start(preferences: preferences)
        transport.emit(RealtimeEvent(type: "session.updated", turnDetectionDisabled: true))
        await Task.yield()

        await call.startTurn()
        XCTAssertEqual(call.phase, .ready)
        XCTAssertFalse(transport.inputEnabled)
        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertEqual(call.message, "Could not prepare the turn. Try again.")

        let retry = Task { await call.startTurn() }
        await Task.yield()
        transport.emit(RealtimeEvent(type: "input_audio_buffer.cleared"))
        await retry.value
        XCTAssertEqual(call.phase, .recording)
    }

    func testDisconnectDuringBufferClearIgnoresLateAcknowledgement() async {
        let transport = FakeTransport()
        let recorder = FakeRecorder()
        let call = CallCoordinator(backend: FakeBackend(), permission: FakePermission(allowed: true),
                                   transport: transport, recorder: recorder)
        await call.start(preferences: preferences)
        transport.emit(RealtimeEvent(type: "session.updated", turnDetectionDisabled: true))
        await Task.yield()
        let pending = Task { await call.startTurn() }
        await Task.yield()
        let oldCallback = transport.onEvent
        await call.disconnect()
        oldCallback?(RealtimeEvent(type: "input_audio_buffer.cleared"))
        await pending.value
        XCTAssertEqual(call.phase, .idle)
        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertFalse(transport.inputEnabled)
    }

    func testKeyedReplayWithoutCredentialEndsKnownSession() async {
        let backend = FakeBackend()
        backend.returnCredential = false
        let transport = FakeTransport()
        let call = CallCoordinator(backend: backend, permission: FakePermission(allowed: true),
                                   transport: transport, recorder: FakeRecorder())
        await call.start(preferences: preferences)
        XCTAssertEqual(call.phase, .failed)
        XCTAssertEqual(backend.endCount, 1)
        XCTAssertEqual(transport.connectCount, 0)
    }

    func testRealtimeEventsDecodeProviderItemAndManualTurnSetting() {
        let sessionEvent = RealtimeEvent(data: Data("""
        {"type":"session.updated","session":{"audio":{"input":{"turn_detection":null}}}}
        """.utf8))
        XCTAssertEqual(sessionEvent?.turnDetectionDisabled, true)
        let committed = RealtimeEvent(data: Data("""
        {"type":"input_audio_buffer.committed","item_id":"item-42"}
        """.utf8))
        XCTAssertEqual(committed?.itemID, "item-42")
        XCTAssertNil(RealtimeEvent(data: Data("{}".utf8)))
    }

    func testConversationEventsReachDurableJournal() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "call-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PracticeStore(directory: root)
        let transport = FakeTransport()
        let call = CallCoordinator(backend: FakeBackend(), permission: FakePermission(allowed: true),
                                   transport: transport, recorder: FileRecorder(root: root), store: store)
        await call.start(preferences: preferences)
        XCTAssertEqual(store.practices.count, 1)
        transport.emit(RealtimeEvent(type: "session.updated", turnDetectionDisabled: true))
        await Task.yield()
        let starting = Task { await call.startTurn() }
        await Task.yield()
        transport.emit(RealtimeEvent(type: "input_audio_buffer.cleared"))
        await starting.value
        await call.finishTurn()
        transport.emit(RealtimeEvent(type: "input_audio_buffer.committed", itemID: "learner-1"))
        transport.emit(RealtimeEvent(type: "conversation.item.input_audio_transcription.completed",
                                     itemID: "learner-1", transcript: "My answer"))
        transport.emit(RealtimeEvent(type: "response.output_audio_transcript.done", itemID: "agent-1",
                                     transcript: "Good answer", contentIndex: 0, responseID: "response-1"))
        await Task.yield()
        XCTAssertEqual(Set(store.journal.map(\.kind)), Set(["audio", "learnerTranscript", "agentTranscript"]))
        XCTAssertEqual(store.parts.filter { !$0.text.isEmpty }.count, 2)
        await call.endAndGetFeedback()
        XCTAssertEqual(store.practices.first?.status, "ended")
    }
}

private final class FileRecorder: TurnRecording {
    let root: URL
    init(root: URL) { self.root = root }
    func start(turnID: UUID) throws {}
    func stop() throws -> URL {
        let url = root.appending(path: "turn.wav")
        try Data(repeating: 1, count: 100).write(to: url)
        return url
    }
    func cancel() {}
}

private struct FakePermission: MicrophonePermissionProviding {
    let allowed: Bool
    func request() async -> Bool { allowed }
}

private final class FakeBackend: BackendServing {
    var createCount = 0
    var endCount = 0
    var heartbeatCount = 0
    var key: UUID?
    var returnCredential = true

    func createSession(_ preferences: SessionPreferences, key: UUID) async throws -> SessionStart {
        createCount += 1
        self.key = key
        let data = Data("""
        {"session":{"id":"10000000-0000-4000-8000-000000000001","status":"active"},
         "realtime":{"webrtc_url":"https://example.com/openai/v1/realtime/calls",
         "client_credential":{"value":"test-token","expires_at":"2099-01-01T00:00:00Z"}}}
        """.utf8)
        let start = try JSONDecoder().decode(SessionStart.self, from: data)
        return returnCredential ? start : SessionStart(session: start.session, realtime: nil)
    }

    func endSession(_ id: UUID) async throws { endCount += 1 }
    func heartbeat(_ id: UUID) async throws { heartbeatCount += 1 }
}

private final class FakeTransport: RealtimeTransporting {
    var onEvent: ((RealtimeEvent) -> Void)?
    var connectCount = 0
    var closeCount = 0
    var connectError: Error?
    var inputEnabled = false
    var sent: [[String: Any]] = []
    var onConnect: (() async throws -> Void)?

    func connect(url: URL, credential: String) async throws {
        connectCount += 1
        try await onConnect?()
        if let connectError { throw connectError }
    }
    func send(_ payload: [String: Any]) throws { sent.append(payload) }
    func setInputEnabled(_ enabled: Bool) { inputEnabled = enabled }
    func setSpeakerEnabled(_ enabled: Bool) throws {}
    func close() { closeCount += 1 }
    func emit(_ event: RealtimeEvent) { onEvent?(event) }
}

private final class FakeRecorder: TurnRecording {
    var startCount = 0
    func start(turnID: UUID) throws { startCount += 1 }
    func stop() throws -> URL { FileManager.default.temporaryDirectory.appending(path: "test.wav") }
    func cancel() {}
}
