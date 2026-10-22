import AVFoundation
import XCTest
#if canImport(WebRTC)
import WebRTC
#endif
@testable import SpokenAgents

@MainActor final class WebRTCAudioCaptureTests: XCTestCase {
    #if canImport(WebRTC)
    func testNativeProcessingModuleAttachesCaptureDelegate() {
        let capture = WebRTCAudioCapture()
        let module = NativeRealtimeTransport.makeAudioProcessingModule(capture: capture)
        XCTAssertTrue(module.capturePostProcessingDelegate === capture)
        XCTAssertNil(module.renderPreProcessingDelegate)
        // These delegates are weak in WebRTC; their owners must keep them alive.
        let factory = RTCPeerConnectionFactory(audioDeviceModuleType: .platformDefault,
            bypassVoiceProcessing: false, encoderFactory: nil, decoderFactory: nil,
            audioProcessingModule: module)
        XCTAssertTrue(module.capturePostProcessingDelegate === capture)
        XCTAssertNil(module.renderPreProcessingDelegate)
        withExtendedLifetime(factory) {}
    }
    #endif
    private func assertStopFailure(_ capture: WebRTCAudioCapture, expected: RecordingFailure,
                                   file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let url = try await capture.stop()
            try? FileManager.default.removeItem(at: url)
            XCTFail("Expected recording failure", file: file, line: line)
        } catch { XCTAssertEqual(error as? RecordingFailure, expected, file: file, line: line) }
    }

    private func feed(_ capture: WebRTCAudioCapture, rate: Int = 48_000,
                      channels: Int = 1, amplitude: Float = 8192, blocks: Int = 10) {
        let samples = [Float](repeating: amplitude, count: rate / 100)
        samples.withUnsafeBufferPointer { buffer in
            for _ in 0..<blocks {
                capture.receive(frames: buffer.count, channels: channels) { _ in buffer.baseAddress! }
            }
        }
    }

    func testConvertsFloatS16StereoToSixteenKilohertzMonoWAV() async throws {
        let capture = WebRTCAudioCapture(bufferCount: 200)
        capture.initialize(sampleRate: 48_000, channels: 2)
        try await capture.start(turnID: UUID())
        feed(capture, channels: 2, blocks: 100)
        let url = try await capture.stop()
        defer { try? FileManager.default.removeItem(at: url) }
        let evidence = try RecordingEvidence.inspect(url)
        XCTAssertEqual(evidence.duration, 1, accuracy: 0.002)
        XCTAssertEqual(evidence.rms, 0.25, accuracy: 0.005)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16)
    }

    func testTurnBoundaryExcludesIdleSamplesAndDoesNotReusePreviousTurn() async throws {
        let capture = WebRTCAudioCapture(bufferCount: 100)
        capture.initialize(sampleRate: 16_000, channels: 1)
        feed(capture, rate: 16_000, amplitude: 30_000)
        for amplitude: Float in [8192, 16384] {
            try await capture.start(turnID: UUID())
            feed(capture, rate: 16_000, amplitude: amplitude)
            let url = try await capture.stop()
            defer { try? FileManager.default.removeItem(at: url) }
            let evidence = try RecordingEvidence.inspect(url)
            XCTAssertEqual(evidence.duration, 0.1, accuracy: 0.002)
            XCTAssertEqual(evidence.rms, Double(amplitude) / 32768, accuracy: 0.005)
            feed(capture, rate: 16_000, amplitude: 30_000)
        }
    }

    func testCaptureMayInitializeAfterTurnStarts() async throws {
        let capture = WebRTCAudioCapture()
        try await capture.start(turnID: UUID())
        capture.initialize(sampleRate: 16_000, channels: 1)
        feed(capture, rate: 16_000)
        let url = try await capture.stop()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertGreaterThan(try RecordingEvidence.inspect(url).frames, 0)
    }

    func testSilenceAndMissingCallbacksFailWithoutReturningAFile() async throws {
        let capture = WebRTCAudioCapture()
        capture.initialize(sampleRate: 16_000, channels: 1)
        try await capture.start(turnID: UUID())
        await assertStopFailure(capture, expected: .noAudio)
        try await capture.start(turnID: UUID())
        feed(capture, rate: 16_000, amplitude: 0)
        await assertStopFailure(capture, expected: .noAudio)
    }

    func testFormatChangeAndCaptureReleaseInvalidateTheTurn() async throws {
        let capture = WebRTCAudioCapture()
        capture.initialize(sampleRate: 16_000, channels: 1)
        try await capture.start(turnID: UUID())
        feed(capture, rate: 16_000)
        capture.initialize(sampleRate: 48_000, channels: 1)
        await assertStopFailure(capture, expected: .invalidFile)
        try await capture.start(turnID: UUID())
        capture.releaseCapture()
        await assertStopFailure(capture, expected: .invalidFile)
    }

    func testCancelAndInvalidBlockDoNotProduceSuccessfulRecording() async throws {
        let capture = WebRTCAudioCapture()
        capture.initialize(sampleRate: 16_000, channels: 1)
        try await capture.start(turnID: UUID())
        capture.cancel()
        await assertStopFailure(capture, expected: .notRecording)
        try await capture.start(turnID: UUID())
        capture.receive(frames: 161, channels: 1) { _ in XCTFail("Must reject before reading"); fatalError() }
        await assertStopFailure(capture, expected: .invalidFile)
    }

    func testPoolOverflowFailsAndCopiedSamplesOutliveTheCallback() async throws {
        let queue = DispatchQueue(label: "capture-test-worker")
        let capture = WebRTCAudioCapture(bufferCount: 2, workerQueue: queue)
        capture.initialize(sampleRate: 16_000, channels: 1)
        try await capture.start(turnID: UUID())
        queue.suspend()
        feed(capture, rate: 16_000, blocks: 3)
        queue.resume()
        await assertStopFailure(capture, expected: .invalidFile)

        try await capture.start(turnID: UUID())
        queue.suspend()
        var samples = [Float](repeating: 8192, count: 160)
        samples.withUnsafeMutableBufferPointer { buffer in
            capture.receive(frames: 160, channels: 1) { _ in UnsafePointer(buffer.baseAddress!) }
            buffer.update(repeating: 0)
        }
        queue.resume()
        let url = try await capture.stop()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try RecordingEvidence.inspect(url).rms, 0.25, accuracy: 0.005)
    }

    func testCancelDuringSuspendedWorkerStartAndStopRejectsLateResults() async throws {
        let queue = DispatchQueue(label: "suspended-capture-worker")
        let capture = WebRTCAudioCapture(workerQueue: queue)
        capture.initialize(sampleRate: 16_000, channels: 1)
        queue.suspend()
        let startEntered = expectation(description: "start entered")
        let starting = Task { @MainActor in
            startEntered.fulfill()
            try await capture.start(turnID: UUID())
        }
        await fulfillment(of: [startEntered], timeout: 1)
        capture.cancel() // Returns even while the file worker is suspended.
        queue.resume()
        do { try await starting.value; XCTFail("Cancelled start must fail") }
        catch { XCTAssertTrue(error is CancellationError) }

        try await capture.start(turnID: UUID())
        queue.suspend()
        feed(capture, rate: 16_000, blocks: 1)
        let stopEntered = expectation(description: "stop entered")
        let stopping = Task { @MainActor in
            stopEntered.fulfill()
            return try await capture.stop()
        }
        await fulfillment(of: [stopEntered], timeout: 1)
        capture.cancel()
        queue.resume()
        do {
            let url = try await stopping.value
            try? FileManager.default.removeItem(at: url)
            XCTFail("Cancelled stop must fail")
        } catch { XCTAssertTrue(error is CancellationError) }

        try await capture.start(turnID: UUID())
        feed(capture, rate: 16_000)
        let url = try await capture.stop()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertGreaterThan(try RecordingEvidence.inspect(url).frames, 0)
    }
    private func recordingDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "capture-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func workerBarrier(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    func testBackgroundProducerAndWorkerPreserveFramesAcrossRingWraps() async throws {
        let capture = WebRTCAudioCapture(bufferCount: 64)
        capture.initialize(sampleRate: 16_000, channels: 1)
        try await capture.start(turnID: UUID())
        let produced = expectation(description: "background capture finished")
        DispatchQueue(label: "simulated-webrtc-capture").async {
            var samples = [Float](repeating: 8192, count: 160)
            samples.withUnsafeMutableBufferPointer { buffer in
                for _ in 0..<200 {
                    buffer.update(repeating: 8192)
                    capture.receive(frames: 160, channels: 1) { _ in UnsafePointer(buffer.baseAddress!) }
                    buffer.update(repeating: 0) // Reuse borrowed memory immediately.
                    Thread.sleep(forTimeInterval: 0.002)
                }
            }
            produced.fulfill()
        }
        await fulfillment(of: [produced], timeout: 5)
        let url = try await capture.stop()
        defer { try? FileManager.default.removeItem(at: url) }
        let evidence = try RecordingEvidence.inspect(url)
        XCTAssertEqual(evidence.frames, 32_000)
        XCTAssertEqual(evidence.rms, 0.25, accuracy: 0.005)
    }

    func testOverlappingCaptureCallbacksFailWithoutBlockingOrLeavingAFile() async throws {
        let root = try recordingDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchQueue(label: "overlapping-capture-worker")
        let capture = WebRTCAudioCapture(workerQueue: queue, recordingDirectory: root)
        capture.initialize(sampleRate: 16_000, channels: 1)
        try await capture.start(turnID: UUID())
        let entered = expectation(description: "first callback owns gate")
        let finished = expectation(description: "first callback finished")
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let samples = [Float](repeating: 8192, count: 160)
            samples.withUnsafeBufferPointer { buffer in
                capture.receive(frames: 160, channels: 1) { _ in
                    entered.fulfill()
                    _ = release.wait(timeout: .now() + 5)
                    return buffer.baseAddress!
                }
            }
            finished.fulfill()
        }
        await fulfillment(of: [entered], timeout: 2)
        // A second producer cannot access the occupied gate and must return.
        capture.receive(frames: 160, channels: 1) { _ in
            XCTFail("Contending callback must not read its borrowed buffer")
            fatalError()
        }
        release.signal()
        await fulfillment(of: [finished], timeout: 2)
        await assertStopFailure(capture, expected: .invalidFile)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testCancelledTaskClosesPendingWriterAndFreshTurnIsIndependent() async throws {
        let root = try recordingDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchQueue(label: "task-cancel-worker")
        let capture = WebRTCAudioCapture(workerQueue: queue, recordingDirectory: root)
        capture.initialize(sampleRate: 16_000, channels: 1)
        try await capture.start(turnID: UUID())
        feed(capture, rate: 16_000)
        queue.suspend()
        let entered = expectation(description: "stop suspended")
        let stopping = Task { @MainActor in
            entered.fulfill()
            return try await capture.stop()
        }
        await fulfillment(of: [entered], timeout: 1)
        stopping.cancel() // No explicit recorder.cancel() call.
        queue.resume()
        do { _ = try await stopping.value; XCTFail("Cancelled task must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        await workerBarrier(queue)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        try await capture.start(turnID: UUID())
        feed(capture, rate: 16_000, amplitude: 16384, blocks: 1)
        let url = try await capture.stop()
        defer { try? FileManager.default.removeItem(at: url) }
        let evidence = try RecordingEvidence.inspect(url)
        XCTAssertEqual(evidence.frames, 160)
        XCTAssertEqual(evidence.rms, 0.5, accuracy: 0.005)
    }

    func testAbandonedRecorderReleasesObserverAndDeletesUnfinishedWAV() async throws {
        let root = try recordingDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchQueue(label: "abandoned-capture-worker")
        var capture: WebRTCAudioCapture? = WebRTCAudioCapture(workerQueue: queue, recordingDirectory: root)
        weak var weakCapture = capture
        capture!.initialize(sampleRate: 16_000, channels: 1)
        try await capture!.start(turnID: UUID())
        feed(capture!, rate: 16_000)
        await workerBarrier(queue)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        capture = nil
        await workerBarrier(queue)
        XCTAssertNil(weakCapture)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testConcurrentCancellationLeavesNoFilesAndRecorderCanRestart() async throws {
        let root = try recordingDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchQueue(label: "repeated-cancel-worker")
        let capture = WebRTCAudioCapture(workerQueue: queue, recordingDirectory: root)
        capture.initialize(sampleRate: 16_000, channels: 1)
        try await capture.start(turnID: UUID())
        feed(capture, rate: 16_000)
        await Task.detached {
            DispatchQueue.concurrentPerform(iterations: 32) { _ in capture.cancel() }
        }.value
        await workerBarrier(queue)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        try await capture.start(turnID: UUID())
        feed(capture, rate: 16_000, blocks: 1)
        let url = try await capture.stop()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try RecordingEvidence.inspect(url).frames, 160)
    }

    func testCancelledStartTaskCleansUpWithoutExplicitRecorderCancel() async throws {
        let root = try recordingDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchQueue(label: "cancel-start-task")
        let capture = WebRTCAudioCapture(workerQueue: queue, recordingDirectory: root)
        capture.initialize(sampleRate: 16_000, channels: 1)
        queue.suspend()
        let entered = expectation(description: "start suspended")
        let starting = Task { @MainActor in entered.fulfill(); try await capture.start(turnID: UUID()) }
        await fulfillment(of: [entered], timeout: 1)
        starting.cancel()
        queue.resume()
        do { try await starting.value; XCTFail("Cancelled start must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        await workerBarrier(queue)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        try await capture.start(turnID: UUID())
        feed(capture, rate: 16_000, blocks: 1)
        let url = try await capture.stop()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try RecordingEvidence.inspect(url).frames, 160)
    }

    func testDuplicateStartWhileWorkerIsOpeningDoesNotReplaceFirstTurn() async throws {
        let root = try recordingDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchQueue(label: "duplicate-start")
        let capture = WebRTCAudioCapture(workerQueue: queue, recordingDirectory: root)
        capture.initialize(sampleRate: 16_000, channels: 1)
        let firstID = UUID()
        queue.suspend()
        let entered = expectation(description: "first start suspended")
        let first = Task { @MainActor in entered.fulfill(); try await capture.start(turnID: firstID) }
        await fulfillment(of: [entered], timeout: 1)
        do { try await capture.start(turnID: UUID()); XCTFail("Duplicate start must fail") }
        catch { XCTAssertEqual(error as? RecordingFailure, .couldNotStart) }
        queue.resume()
        try await first.value
        feed(capture, rate: 16_000, blocks: 1)
        let url = try await capture.stop()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(url.lastPathComponent.contains(firstID.uuidString))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
    }

    func testNonfinitePCMDeletesFailedFileAndDoesNotPoisonNextTurn() async throws {
        let root = try recordingDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = WebRTCAudioCapture(recordingDirectory: root)
        capture.initialize(sampleRate: 16_000, channels: 1)
        for amplitude: Float in [.nan, .infinity, -.infinity] {
            try await capture.start(turnID: UUID())
            feed(capture, rate: 16_000, amplitude: amplitude, blocks: 1)
            await assertStopFailure(capture, expected: .invalidFile)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
        try await capture.start(turnID: UUID())
        feed(capture, rate: 16_000, blocks: 1)
        let url = try await capture.stop()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertGreaterThan(try RecordingEvidence.inspect(url).rms, 0)
    }

    func testEightAndThirtyTwoKilohertzTurnsResampleWithoutCrossTurnState() async throws {
        let capture = WebRTCAudioCapture(bufferCount: 120)
        for rate in [8_000, 32_000, 16_000] {
            capture.initialize(sampleRate: rate, channels: 1)
            try await capture.start(turnID: UUID())
            feed(capture, rate: rate, blocks: 100)
            let url = try await capture.stop()
            defer { try? FileManager.default.removeItem(at: url) }
            let evidence = try RecordingEvidence.inspect(url)
            XCTAssertEqual(evidence.duration, 1, accuracy: 0.002)
            XCTAssertEqual(evidence.rms, 0.25, accuracy: 0.005)
        }
    }

    func testWriterCreationFailureReleasesStartStateForRetry() async throws {
        let root = try recordingDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appending(path: "not-created")
        let capture = WebRTCAudioCapture(recordingDirectory: missing)
        capture.initialize(sampleRate: 16_000, channels: 1)
        do { try await capture.start(turnID: UUID()); XCTFail("Missing directory must fail") }
        catch { XCTAssertFalse(error is CancellationError) }
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        try await capture.start(turnID: UUID())
        feed(capture, rate: 16_000, blocks: 1)
        let url = try await capture.stop()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try RecordingEvidence.inspect(url).frames, 160)
    }

    func testStartRacingBackgroundCancellationEventuallyLeavesCleanRestartableState() async throws {
        let root = try recordingDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchQueue(label: "start-cancel-race")
        let capture = WebRTCAudioCapture(workerQueue: queue, recordingDirectory: root)
        capture.initialize(sampleRate: 16_000, channels: 1)
        for _ in 0..<25 {
            let cancelling = Task.detached {
                DispatchQueue.concurrentPerform(iterations: 8) { _ in capture.cancel() }
            }
            do { try await capture.start(turnID: UUID()) }
            catch { XCTAssertTrue(error is CancellationError) }
            await cancelling.value
            capture.cancel()
            await workerBarrier(queue)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
        try await capture.start(turnID: UUID())
        feed(capture, rate: 16_000, blocks: 1)
        let url = try await capture.stop()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try RecordingEvidence.inspect(url).frames, 160)
    }

}
