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
}

private struct FakePermission: MicrophonePermissionProviding {
    let allowed: Bool
    func request() async -> Bool { allowed }
}

private final class FakeBackend: BackendServing {
    var createCount = 0
    var endCount = 0
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
}

private final class FakeTransport: RealtimeTransporting {
    var onEvent: ((RealtimeEvent) -> Void)?
    var connectCount = 0
    var closeCount = 0
    var connectError: Error?
    var inputEnabled = false
    var sent: [[String: Any]] = []

    func connect(url: URL, credential: String) async throws {
        connectCount += 1
        if let connectError { throw connectError }
    }
    func send(_ payload: [String: Any]) throws { sent.append(payload) }
    func setInputEnabled(_ enabled: Bool) { inputEnabled = enabled }
    func close() { closeCount += 1 }
    func emit(_ event: RealtimeEvent) { onEvent?(event) }
}

private final class FakeRecorder: TurnRecording {
    var startCount = 0
    func start(turnID: UUID) throws { startCount += 1 }
    func stop() throws -> URL { FileManager.default.temporaryDirectory.appending(path: "test.wav") }
    func cancel() {}
}
