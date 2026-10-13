import XCTest
import Synchronization
@testable import SpokenAgents

@MainActor
final class CallCoordinatorTests: XCTestCase {
    private let preferences = SessionPreferences(speakingGoal: "Interview practice", level: "B1",
                                                 preferredTopic: nil, sessionDurationMinutes: 10)

    func testSessionCreationFailureAllowsRetry() async {
        let backend = FakeBackend()
        backend.createError = BackendFailure.status(503)
        let transport = FakeTransport()
        let call = CallCoordinator(backend: backend, permission: FakePermission(allowed: true), transport: transport, recorder: FakeRecorder())
        await call.start(preferences: preferences)
        XCTAssertEqual(call.phase, .failed)
        XCTAssertEqual(transport.connectCount, 0)
        XCTAssertEqual(backend.endCount, 0)
        backend.createError = nil
        await call.start(preferences: preferences)
        XCTAssertEqual(call.phase, .connecting)
        XCTAssertEqual(backend.createCount, 2)
        await call.disconnect()
    }

    func testHeartbeatDoesNotRetainAbandonedCoordinatorAndMediaIsClosed() async throws {
        let backend = FakeBackend(), transport = FakeTransport(), recorder = FakeRecorder()
        var call: CallCoordinator? = CallCoordinator(backend: backend, permission: FakePermission(allowed: true),
                                                   transport: transport, recorder: recorder,
                                                   heartbeatNanoseconds: 1_000_000)
        weak var weakCall = call
        await call!.start(preferences: preferences)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertGreaterThan(backend.heartbeatCount, 0)
        call = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(weakCall)
        XCTAssertEqual(transport.closeCount, 1)
        XCTAssertEqual(recorder.cancelCount, 1)
        XCTAssertEqual(backend.endCount, 1)
        let heartbeats = backend.heartbeatCount
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(backend.heartbeatCount, heartbeats)
    }

    private func prepareTurn(_ call: CallCoordinator, transport: FakeTransport) async {
        await call.start(preferences: preferences)
        transport.emit(RealtimeEvent(type: "session.updated", turnDetectionDisabled: true))
        await Task.yield()
        let starting = Task { await call.startTurn() }
        await Task.yield()
        transport.emit(RealtimeEvent(type: "input_audio_buffer.cleared"))
        await starting.value
    }

    func testMicrophoneStartupFailureEndsSessionBeforeOpeningWriter() async {
        let backend = FakeBackend(), transport = FakeTransport(), recorder = FakeRecorder()
        transport.inputStartError = RealtimeFailure.microphoneStartupFailed
        let call = CallCoordinator(backend: backend, permission: FakePermission(allowed: true),
                                   transport: transport, recorder: recorder)
        await prepareTurn(call, transport: transport)
        XCTAssertEqual(call.phase, .failed)
        XCTAssertFalse(transport.inputEnabled)
        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertGreaterThan(recorder.cancelCount, 0)
        XCTAssertFalse(transport.sent.contains { $0["type"] as? String == "input_audio_buffer.commit" })
    }

    func testWebRTCTurnWorksWithoutLocalRecorder() async {
        let backend = FakeBackend(), transport = FakeTransport()
        let call = CallCoordinator(backend: backend, permission: FakePermission(allowed: true),
                                   transport: transport, recorder: nil)
        XCTAssertFalse(call.supportsAudioFeedback)
        await prepareTurn(call, transport: transport)
        XCTAssertEqual(call.phase, .recording)
        XCTAssertTrue(transport.inputEnabled)
        await call.finishTurn()
        XCTAssertTrue(transport.inputEnabled)
        XCTAssertEqual(transport.inputStartCount, 1)
        XCTAssertEqual(call.phase, .waitingForTranscript)
        XCTAssertTrue(transport.sent.contains { $0["type"] as? String == "input_audio_buffer.commit" })
        XCTAssertTrue(transport.sent.contains { $0["type"] as? String == "response.create" })
        await call.disconnect()
        XCTAssertFalse(transport.inputEnabled)
    }

    func testRecorderStartFailureLeavesInputMutedAndEndsSession() async {
        let backend = FakeBackend(), transport = FakeTransport(), recorder = FakeRecorder()
        recorder.startError = URLError(.cannotCreateFile)
        let call = CallCoordinator(backend: backend, permission: FakePermission(allowed: true), transport: transport, recorder: recorder)
        await prepareTurn(call, transport: transport)
        XCTAssertEqual(call.phase, .failed)
        XCTAssertFalse(transport.inputEnabled)
        XCTAssertEqual(backend.endCount, 1)
        XCTAssertEqual(transport.closeCount, 1)
    }

    func testDisconnectDuringAsyncRecorderStartCannotEnableInput() async {
        let transport = FakeTransport(), recorder = FakeRecorder()
        let entered = expectation(description: "recorder start suspended")
        var resume: CheckedContinuation<Void, Never>?
        recorder.onStart = {
            await withCheckedContinuation { resume = $0; entered.fulfill() }
        }
        let call = CallCoordinator(backend: FakeBackend(), permission: FakePermission(allowed: true),
                                   transport: transport, recorder: recorder)
        let starting = Task { await prepareTurn(call, transport: transport) }
        await fulfillment(of: [entered], timeout: 2)
        await call.disconnect()
        resume?.resume()
        await starting.value
        XCTAssertEqual(call.phase, .idle)
        XCTAssertFalse(transport.inputEnabled)
        XCTAssertEqual(recorder.cancelCount, 1)
    }

    func testDisconnectDuringAsyncStopRejectsLateRecording() async {
        let transport = FakeTransport(), recorder = FakeRecorder()
        let entered = expectation(description: "recorder stop suspended")
        var resume: CheckedContinuation<Void, Never>?
        recorder.onStop = {
            await withCheckedContinuation { resume = $0; entered.fulfill() }
        }
        let call = CallCoordinator(backend: FakeBackend(), permission: FakePermission(allowed: true),
                                   transport: transport, recorder: recorder)
        await prepareTurn(call, transport: transport)
        let stopping = Task { await call.finishTurn() }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(call.phase, .finalizingTurn)
        await call.disconnect()
        resume?.resume()
        await stopping.value
        XCTAssertEqual(call.phase, .idle)
        XCTAssertFalse(transport.sent.contains { $0["type"] as? String == "input_audio_buffer.commit" })
    }

    func testRepeatedFinishWhileAsyncStopWaitsFinalizesOnlyOnce() async {
        let transport = FakeTransport(), recorder = FakeRecorder()
        let entered = expectation(description: "stop suspended")
        var resume: CheckedContinuation<Void, Never>?
        recorder.onStop = {
            await withCheckedContinuation { resume = $0; entered.fulfill() }
        }
        let call = CallCoordinator(backend: FakeBackend(), permission: FakePermission(allowed: true),
                                   transport: transport, recorder: recorder)
        await prepareTurn(call, transport: transport)
        let first = Task { await call.finishTurn() }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task { await call.finishTurn() }
        await Task.yield()
        resume?.resume()
        await first.value
        await second.value
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertEqual(transport.sent.filter { $0["type"] as? String == "input_audio_buffer.commit" }.count, 1)
        await call.disconnect()
    }

    func testAccountChangeDuringFinalizationDiscardsLateFileAndEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "late-turn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = FakeTransport(), recorder = FakeRecorder()
        recorder.stopURL = root.appending(path: "late.wav")
        try Data(repeating: 1, count: 100).write(to: recorder.stopURL)
        let entered = expectation(description: "finalization suspended")
        var resume: CheckedContinuation<Void, Never>?
        recorder.onStop = { await withCheckedContinuation { resume = $0; entered.fulfill() } }
        let call = CallCoordinator(backend: FakeBackend(), permission: FakePermission(allowed: true),
                                   transport: transport, recorder: recorder)
        await prepareTurn(call, transport: transport)
        let oldCallback = transport.onEvent
        let finishing = Task { await call.finishTurn() }
        await fulfillment(of: [entered], timeout: 2)
        call.accountDidChange()
        resume?.resume()
        await finishing.value
        oldCallback?(RealtimeEvent(type: "input_audio_buffer.committed", itemID: "old-item"))
        oldCallback?(RealtimeEvent(type: "conversation.item.input_audio_transcription.completed", itemID: "old-item", transcript: "Old account text"))
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: recorder.stopURL.path) { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(call.phase, .idle)
        XCTAssertTrue(call.transcripts.isEmpty)
        XCTAssertFalse(transport.inputEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorder.stopURL.path))
        XCTAssertFalse(transport.sent.contains { $0["type"] as? String == "input_audio_buffer.commit" })
    }

    func testEndDuringFinalizationWaitsAndCommitsTurnExactlyOnce() async {
        let backend = FakeBackend(), transport = FakeTransport(), recorder = FakeRecorder()
        let entered = expectation(description: "stop suspended")
        var resume: CheckedContinuation<Void, Never>?
        recorder.onStop = { await withCheckedContinuation { resume = $0; entered.fulfill() } }
        let call = CallCoordinator(backend: backend, permission: FakePermission(allowed: true),
                                   transport: transport, recorder: recorder)
        await prepareTurn(call, transport: transport)
        transport.onSend = { payload in
            if payload["type"] as? String == "input_audio_buffer.commit" {
                transport.emit(RealtimeEvent(type: "input_audio_buffer.committed", itemID: "last-turn"))
                transport.emit(RealtimeEvent(type: "conversation.item.input_audio_transcription.completed", itemID: "last-turn", transcript: "Final answer"))
            }
        }
        let finishing = Task { await call.finishTurn() }
        await fulfillment(of: [entered], timeout: 2)
        let ending = Task { await call.endAndGetFeedback() }
        await Task.yield()
        XCTAssertEqual(call.phase, .finalizingTurn)
        XCTAssertEqual(backend.endCount, 0)
        resume?.resume()
        await finishing.value
        await ending.value
        transport.onSend = nil
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertEqual(backend.endCount, 1)
        XCTAssertEqual(transport.sent.filter { $0["type"] as? String == "input_audio_buffer.commit" }.count, 1)
        XCTAssertEqual(call.phase, .completed)
    }

    func testSilentTurnDoesNotDisconnectOrCommitAndCanBeRetried() async {
        let backend = FakeBackend(), transport = FakeTransport(), recorder = FakeRecorder()
        recorder.stopError = RecordingFailure.noAudio
        let call = CallCoordinator(backend: backend, permission: FakePermission(allowed: true),
                                   transport: transport, recorder: recorder)
        await prepareTurn(call, transport: transport)
        await call.finishTurn()
        XCTAssertEqual(call.phase, .ready)
        XCTAssertEqual(backend.endCount, 0)
        XCTAssertEqual(transport.closeCount, 0)
        XCTAssertFalse(transport.sent.contains { $0["type"] as? String == "input_audio_buffer.commit" })
        XCTAssertTrue(call.message?.contains("No microphone audio") == true)
        recorder.stopError = nil
        let retry = Task { await call.startTurn() }
        await Task.yield()
        transport.emit(RealtimeEvent(type: "input_audio_buffer.cleared"))
        await retry.value
        XCTAssertEqual(call.phase, .recording)
        await call.finishTurn()
        XCTAssertEqual(call.phase, .waitingForTranscript)
        await call.disconnect()
    }

    func testRepeatedStartAndFinishDoNotDuplicateTurns() async {
        let transport = FakeTransport(), recorder = FakeRecorder()
        let call = CallCoordinator(backend: FakeBackend(), permission: FakePermission(allowed: true), transport: transport, recorder: recorder)
        await prepareTurn(call, transport: transport)
        await call.startTurn()
        await call.finishTurn()
        await call.finishTurn()
        XCTAssertEqual(recorder.startCount, 1)
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertEqual(transport.sent.filter { $0["type"] as? String == "input_audio_buffer.commit" }.count, 1)
        XCTAssertEqual(call.phase, .waitingForTranscript)
        await call.disconnect()
    }

    func testBackgroundInterruptionDuringRecordingCleansUpOnce() async {
        let backend = FakeBackend(), transport = FakeTransport(), recorder = FakeRecorder()
        let call = CallCoordinator(backend: backend, permission: FakePermission(allowed: true), transport: transport, recorder: recorder)
        await prepareTurn(call, transport: transport)
        await call.stopForInterruption("Practice stopped in the background.")
        await call.stopForInterruption("Practice stopped in the background.")
        XCTAssertEqual(call.phase, .failed)
        XCTAssertFalse(transport.inputEnabled)
        XCTAssertEqual(recorder.stopCount, 0)
        XCTAssertEqual(recorder.cancelCount, 1)
        XCTAssertEqual(backend.endCount, 1)
        XCTAssertEqual(transport.closeCount, 1)
    }

    func testAccountChangeDuringConnectionRejectsLateResult() async {
        let backend = FakeBackend(), transport = FakeTransport()
        let entered = expectation(description: "transport connecting")
        var resume: CheckedContinuation<Void, Never>?
        transport.onConnect = { await withCheckedContinuation { resume = $0; entered.fulfill() } }
        let call = CallCoordinator(backend: backend, permission: FakePermission(allowed: true), transport: transport, recorder: FakeRecorder())
        let starting = Task { await call.start(preferences: preferences) }
        await fulfillment(of: [entered], timeout: 2)
        let callback = transport.onEvent
        call.accountDidChange()
        resume?.resume()
        await starting.value
        callback?(RealtimeEvent(type: "session.updated", turnDetectionDisabled: true))
        await Task.yield()
        XCTAssertEqual(call.phase, .idle)
        XCTAssertTrue(transport.sent.isEmpty)
        XCTAssertEqual(transport.closeCount, 1)
        XCTAssertFalse(transport.inputEnabled)
    }

    func testRecorderFinishFailurePreservesPreviouslySavedWork() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "record-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PracticeStore(directory: root)
        let transport = FakeTransport(), recorder = FakeRecorder()
        recorder.stopError = URLError(.cannotWriteToFile)
        let call = CallCoordinator(backend: FakeBackend(), permission: FakePermission(allowed: true), transport: transport, recorder: recorder, store: store)
        await prepareTurn(call, transport: transport)
        let id = try XCTUnwrap(store.practices.first?.id)
        try store.savePart(id: "agent/0", practiceID: id, speaker: "Agent", text: "Saved answer", offsetMilliseconds: 0)
        await call.finishTurn()
        XCTAssertEqual(call.phase, .failed)
        XCTAssertFalse(transport.inputEnabled)
        XCTAssertFalse(transport.sent.contains { $0["type"] as? String == "input_audio_buffer.commit" })
        let reopened = try PracticeStore(directory: root)
        XCTAssertTrue(reopened.parts.contains { $0.text == "Saved answer" })
        XCTAssertEqual(reopened.practices.first?.status, "incomplete")
    }

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

    func testWebRTCConfigurationRouteChangeDoesNotCancelPendingConnection() async {
        let backend = FakeBackend()
        let transport = FakeTransport()
        var finishConnect: CheckedContinuation<Void, Never>?
        transport.onConnect = { await withCheckedContinuation { finishConnect = $0 } }
        let call = CallCoordinator(backend: backend, permission: FakePermission(allowed: true),
                                   transport: transport, recorder: FakeRecorder())
        let starting = Task { await call.start(preferences: preferences) }
        while finishConnect == nil { await Task.yield() }
        await call.audioRouteChanged(8) // routeConfigurationChange observed on the iPhone.
        await call.audioRouteChanged(1) // Bluetooth activation during setup is not route loss.
        XCTAssertEqual(call.phase, .connecting)
        XCTAssertEqual(transport.closeCount, 0)
        XCTAssertEqual(backend.endCount, 0)
        finishConnect?.resume()
        await starting.value
        transport.emit(RealtimeEvent(type: "session.updated", turnDetectionDisabled: true))
        await Task.yield()
        XCTAssertEqual(call.phase, .ready)
        await call.disconnect()
    }

    func testLostAudioRouteStillStopsPractice() async {
        let backend = FakeBackend()
        let transport = FakeTransport()
        let call = CallCoordinator(backend: backend, permission: FakePermission(allowed: true),
                                   transport: transport, recorder: FakeRecorder())
        await call.start(preferences: preferences)
        await call.audioRouteChanged(2) // oldDeviceUnavailable
        XCTAssertEqual(call.phase, .failed)
        XCTAssertEqual(transport.closeCount, 1)
        XCTAssertEqual(backend.endCount, 1)
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

    func testRecordingAutomaticallyFinishesAtTimeLimit() async throws {
        let transport = FakeTransport()
        let call = CallCoordinator(backend: FakeBackend(), permission: FakePermission(allowed: true),
                                   transport: transport, recorder: FakeRecorder(),
                                   maxTurnNanoseconds: 5_000_000)
        await call.start(preferences: preferences)
        transport.emit(RealtimeEvent(type: "session.updated", turnDetectionDisabled: true))
        await Task.yield()
        let starting = Task { await call.startTurn() }
        await Task.yield()
        transport.emit(RealtimeEvent(type: "input_audio_buffer.cleared"))
        await starting.value
        XCTAssertEqual(call.phase, .recording)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(call.phase, .waitingForTranscript)
        XCTAssertTrue(call.message?.contains("five minutes") == true)
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
        XCTAssertTrue(transport.inputEnabled)
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
        XCTAssertEqual(call.message, "Your conversation took too long to start. Check your internet and try again.")
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

    func testClearTimeoutKeepsSessionCaptureEnabledAndAllowsRetry() async {
        let transport = FakeTransport()
        let recorder = FakeRecorder()
        let call = CallCoordinator(backend: FakeBackend(), permission: FakePermission(allowed: true),
                                   transport: transport, recorder: recorder, clearTimeoutNanoseconds: 1_000_000)
        await call.start(preferences: preferences)
        transport.emit(RealtimeEvent(type: "session.updated", turnDetectionDisabled: true))
        await Task.yield()

        await call.startTurn()
        XCTAssertEqual(call.phase, .ready)
        XCTAssertTrue(transport.inputEnabled)
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
        let capture = WebRTCAudioCapture()
        capture.initialize(sampleRate: 16_000, channels: 1)
        let call = CallCoordinator(backend: FakeBackend(), permission: FakePermission(allowed: true),
                                   transport: transport, recorder: capture, store: store)
        await call.start(preferences: preferences)
        XCTAssertEqual(store.practices.count, 1)
        transport.emit(RealtimeEvent(type: "session.updated", turnDetectionDisabled: true))
        await Task.yield()
        let starting = Task { await call.startTurn() }
        await Task.yield()
        transport.emit(RealtimeEvent(type: "input_audio_buffer.cleared"))
        await starting.value
        let samples = [Float](repeating: 8192, count: 160)
        samples.withUnsafeBufferPointer { buffer in
            for _ in 0..<10 {
                capture.receive(frames: 160, channels: 1) { _ in buffer.baseAddress! }
            }
        }
        await call.finishTurn()
        transport.emit(RealtimeEvent(type: "input_audio_buffer.committed", itemID: "learner-1"))
        transport.emit(RealtimeEvent(type: "conversation.item.input_audio_transcription.completed",
                                     itemID: "learner-1", transcript: "My answer"))
        transport.emit(RealtimeEvent(type: "response.output_audio_transcript.done", itemID: "agent-1",
                                     transcript: "Good answer", contentIndex: 0, responseID: "response-1"))
        await Task.yield()
        XCTAssertEqual(Set(store.journal.map(\.kind)), Set(["audio", "learnerTranscript", "agentTranscript"]))
        let audio = try XCTUnwrap(store.journal.first { $0.kind == "audio" })
        let transcript = try XCTUnwrap(store.journal.first { $0.kind == "learnerTranscript" })
        XCTAssertEqual(audio.id.replacingOccurrences(of: "audio/", with: ""),
                       transcript.id.replacingOccurrences(of: "transcript/", with: ""))
        let saved = root.appending(path: "saved-turn.wav")
        try store.bytes(for: audio).write(to: saved)
        XCTAssertEqual(try RecordingEvidence.inspect(saved).duration, 0.1, accuracy: 0.002)
        XCTAssertEqual(store.parts.filter { !$0.text.isEmpty }.count, 2)
        await call.endAndGetFeedback()
        XCTAssertEqual(store.practices.first?.status, "ended")
    }
}

private struct FakePermission: MicrophonePermissionProviding {
    let allowed: Bool
    func request() async -> Bool { allowed }
}

@MainActor private final class FakeBackend: BackendServing {
    var createCount = 0
    var endCount = 0
    var heartbeatCount = 0
    var key: UUID?
    var returnCredential = true
    var createError: Error?

    func createSession(_ preferences: SessionPreferences, key: UUID) async throws -> SessionStart {
        createCount += 1
        self.key = key
        if let createError { throw createError }
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
    var inputStartError: Error?
    var inputStartCount = 0
    var sent: [[String: Any]] = []
    var onConnect: (() async throws -> Void)?
    var onSend: (([String: Any]) -> Void)?

    func connect(url: URL, credential: String) async throws {
        connectCount += 1
        try await onConnect?()
        if let connectError { throw connectError }
    }
    func send(_ payload: [String: Any]) throws { sent.append(payload); onSend?(payload) }
    func setInputEnabled(_ enabled: Bool) { inputEnabled = enabled }
    func startInput() throws {
        inputStartCount += 1
        if let inputStartError { throw inputStartError }
        inputEnabled = true
    }
    func setSpeakerEnabled(_ enabled: Bool) throws {}
    func close() { closeCount += 1 }
    func emit(_ event: RealtimeEvent) { onEvent?(event) }
}

@MainActor private final class FakeRecorder: TurnRecording {
    var startCount = 0
    var stopCount = 0
    private nonisolated let cancellationCount = Atomic<Int>(0)
    var cancelCount: Int { cancellationCount.load(ordering: .acquiring) }
    var startError: Error?
    var stopError: Error?
    var onStart: (() async -> Void)?
    var onStop: (() async -> Void)?
    var stopURL = FileManager.default.temporaryDirectory.appending(path: "test.wav")
    func start(turnID: UUID) async throws {
        startCount += 1
        await onStart?()
        if let startError { throw startError }
    }
    func stop() async throws -> URL {
        stopCount += 1
        await onStop?()
        if let stopError { throw stopError }
        return stopURL
    }
    nonisolated func cancel() { cancellationCount.wrappingAdd(1, ordering: .acquiringAndReleasing) }
}
