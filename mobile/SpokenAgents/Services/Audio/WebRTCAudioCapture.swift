import AVFoundation
import Foundation
import Synchronization
#if canImport(WebRTC)
import WebRTC
#endif

// Synchronization is explicit: atomic ring/lifecycle state, gated capture format,
// and worker-confined writer state. Control calls are serialized by the coordinator.
final class WebRTCAudioCapture: NSObject, TurnRecording, @unchecked Sendable {
    private final class Slot {
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: 960)
        init() { samples.initialize(repeating: 0, count: 960) }
        var frames = 0
        var channels = 0
        var sampleRate = 0
        func clear() {
            samples.update(repeating: 0, count: 960)
            frames = 0; channels = 0; sampleRate = 0
        }
        deinit { clear(); samples.deallocate() }
    }

    private let slots: [Slot]
    private let capacity: Int
    private let readIndex = Atomic<Int>(0)
    private let writeIndex = Atomic<Int>(0)
    private let accepting = Atomic<Bool>(false)
    private let failedEpoch = Atomic<Int>(-1)
    private let lifecycle = Atomic<Int>(0)
    // Only control operations contend with capture, never disk I/O. The callback
    // tries this lock once; it never waits for a control operation.
    private let gate = NSLock()
    private var sampleRate = 0
    private var channelCount = 0
    private let recordingDirectory: URL
    private let worker: DispatchQueue
    private var signal: DispatchSourceUserDataAdd!
    private var writerEpoch = -1
    private var writer: CaptureWAVWriter?
    private var workerError: Error?
    private let recording = Atomic<Bool>(false)

    init(bufferCount: Int = 20, workerQueue: DispatchQueue? = nil, recordingDirectory: URL? = nil) {
        precondition(bufferCount > 0)
        self.recordingDirectory = recordingDirectory ?? FileManager.default.temporaryDirectory
        capacity = bufferCount
        worker = workerQueue ?? DispatchQueue(label: "spoken.audio-recording", qos: .userInitiated)
        slots = (0..<bufferCount).map { _ in Slot() }
        super.init()
        signal = DispatchSource.makeUserDataAddSource(queue: worker)
        signal.setEventHandler { [weak self] in self?.drain() }
        signal.resume()
    }

    deinit {
        signal.cancel()
        // No handler can be using self when its final reference is released.
        let abandoned = writer
        worker.async { abandoned?.cancel() }
    }

    func initialize(sampleRate: Int, channels: Int) {
        gate.lock()
        defer { gate.unlock() }
        if accepting.load(ordering: .acquiring), self.sampleRate != 0,
           self.sampleRate != sampleRate || channelCount != channels {
            failCapture(for: lifecycle.load(ordering: .acquiring))
        }
        self.sampleRate = sampleRate
        channelCount = channels
    }

    func releaseCapture() {
        gate.lock()
        defer { gate.unlock() }
        if accepting.load(ordering: .acquiring) {
            failCapture(for: lifecycle.load(ordering: .acquiring))
        }
        sampleRate = 0
        channelCount = 0
    }

    /// Borrowed channel pointers are accessed synchronously and never retained.
    /// Each full-band block is 10 ms, up to 48 kHz and two channels in this adapter.
    func receive(frames: Int, channels: Int, channel: (Int) -> UnsafePointer<Float>) {
        let epoch = lifecycle.load(ordering: .acquiring)
        guard accepting.load(ordering: .acquiring), failedEpoch.load(ordering: .acquiring) != epoch else { return }
        guard gate.try() else {
            if accepting.load(ordering: .acquiring), lifecycle.load(ordering: .acquiring) == epoch {
                failCapture(for: epoch)
            }
            return
        }
        defer { gate.unlock() }
        guard accepting.load(ordering: .acquiring), lifecycle.load(ordering: .acquiring) == epoch else { return }
        guard (sampleRate == 8_000 || sampleRate == 16_000 || sampleRate == 32_000 || sampleRate == 48_000),
              channels == channelCount, (1...2).contains(channels),
              frames == sampleRate / 100, frames <= 480 else {
            failCapture(for: epoch)
            return
        }
        let write = writeIndex.load(ordering: .relaxed)
        guard write - readIndex.load(ordering: .acquiring) < capacity else {
            failCapture(for: epoch)
            return
        }
        let slot = slots[write % capacity]
        for index in 0..<channels {
            slot.samples.advanced(by: index * 480).update(from: channel(index), count: frames)
        }
        slot.frames = frames
        slot.channels = channels
        slot.sampleRate = sampleRate
        writeIndex.store(write + 1, ordering: .releasing)
        // Coalesces notifications; no per-block DispatchWorkItem or sample array.
        signal.add(data: 1)
    }

    @MainActor func start(turnID: UUID) async throws {
        let epoch = try beginRecording()
        // The capture format may initialize only after unmuting the input track.
        do {
            try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                worker.async { [self] in
                    do {
                        guard lifecycle.load(ordering: .acquiring) == epoch else { throw CancellationError() }
                        writer?.cancel()
                        clearSlots()
                        writer = try CaptureWAVWriter(turnID: turnID, directory: recordingDirectory)
                        writerEpoch = epoch
                        workerError = nil
                        readIndex.store(0, ordering: .relaxed)
                        writeIndex.store(0, ordering: .relaxed)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            } onCancel: { [self] in cancel(ifCurrent: epoch) }
        } catch {
            if lifecycle.load(ordering: .acquiring) == epoch { recording.store(false, ordering: .releasing) }
            throw error
        }
        if Task.isCancelled { cancel(ifCurrent: epoch); throw CancellationError() }
        try enable(for: epoch)
    }

    private func beginRecording() throws -> Int {
        gate.lock()
        defer { gate.unlock() }
        guard !recording.load(ordering: .acquiring) else { throw RecordingFailure.couldNotStart }
        recording.store(true, ordering: .releasing)
        return lifecycle.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue
    }

    private func enable(for epoch: Int) throws {
        gate.lock()
        defer { gate.unlock() }
        guard lifecycle.load(ordering: .acquiring) == epoch else { throw CancellationError() }
        accepting.store(true, ordering: .releasing)
    }

    @MainActor func stop() async throws -> URL {
        guard recording.load(ordering: .acquiring) else { throw RecordingFailure.notRecording }
        let epoch = lifecycle.load(ordering: .acquiring)
        disable()
        recording.store(false, ordering: .releasing)
        let url = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            worker.async { [self] in
                guard writerEpoch == epoch else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                defer { writer = nil; workerError = nil; clearSlots() }
                do {
                    guard lifecycle.load(ordering: .acquiring) == epoch else { throw CancellationError() }
                    drain()
                    if failedEpoch.load(ordering: .acquiring) == epoch { throw RecordingFailure.invalidFile }
                    if let workerError { throw workerError }
                    guard let writer else { throw RecordingFailure.notRecording }
                    continuation.resume(returning: try writer.finish())
                } catch {
                    writer?.cancel()
                    continuation.resume(throwing: error)
                }
            }
        }
        } onCancel: { [self] in cancel(ifCurrent: epoch) }
        if Task.isCancelled { cancel(ifCurrent: epoch) }
        guard lifecycle.load(ordering: .acquiring) == epoch else {
            worker.async { try? FileManager.default.removeItem(at: url) }
            throw CancellationError()
        }
        return url
    }

    func cancel() {
        cancel(ifCurrent: nil)
    }

    private func cancel(ifCurrent expected: Int?) {
        gate.lock()
        if let expected, lifecycle.load(ordering: .acquiring) != expected { gate.unlock(); return }
        let cancelled = lifecycle.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue
        accepting.store(false, ordering: .releasing)
        recording.store(false, ordering: .releasing)
        gate.unlock()
        worker.async { [self] in
            // A delayed cancellation must not erase a newer turn's writer/ring.
            guard writerEpoch < cancelled else { return }
            writer?.cancel()
            writer = nil
            workerError = nil
            clearSlots()
        }
    }

    private func disable() {
        // Close admission before acquiring the gate so a callback racing stop
        // does not mistake normal turn finalization for lost capture data.
        accepting.store(false, ordering: .releasing)
        gate.lock() // Wait only for an in-flight copy, never the writer.
        gate.unlock()
    }

    private func failCapture(for epoch: Int) {
        // Never let a delayed failure from an older callback replace a newer one.
        var previous = failedEpoch.load(ordering: .acquiring)
        while previous < epoch {
            let result = failedEpoch.compareExchange(expected: previous, desired: epoch,
                                                      ordering: .acquiringAndReleasing)
            if result.exchanged { return }
            previous = result.original
        }
    }

    private func clearSlots() {
        for slot in slots { slot.clear() }
        readIndex.store(0, ordering: .relaxed)
        writeIndex.store(0, ordering: .relaxed)
    }

    private func drain() {
        var read = readIndex.load(ordering: .relaxed)
        while read < writeIndex.load(ordering: .acquiring) {
            let slot = slots[read % capacity]
            if workerError == nil, failedEpoch.load(ordering: .acquiring) != writerEpoch, let writer {
                do {
                    try writer.append(samples: slot.samples, frames: slot.frames,
                                      channels: slot.channels, sampleRate: slot.sampleRate)
                } catch { workerError = error }
            }
            slot.clear()
            read += 1
            readIndex.store(read, ordering: .releasing)
        }
    }
}

#if canImport(WebRTC)
extension WebRTCAudioCapture: RTCAudioCustomProcessingDelegate {
    func audioProcessingInitialize(sampleRate: Int, channels: Int) {
        initialize(sampleRate: sampleRate, channels: channels)
    }
    func audioProcessingProcess(audioBuffer: RTCAudioBuffer) {
        receive(frames: audioBuffer.frames, channels: audioBuffer.channels) {
            UnsafePointer(audioBuffer.rawBuffer(forChannel: $0))
        }
    }
    func audioProcessingRelease() { releaseCapture() }
}
#endif

/// Worker-only streaming converter. WebRTC AudioBuffer uses FloatS16 samples,
/// not normalized Float32: https://github.com/webrtc-sdk/webrtc/blob/m137_release/modules/audio_processing/audio_buffer.cc
private final class CaptureWAVWriter {
    private let url: URL
    private var file: AVAudioFile?
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private let output: AVAudioPCMBuffer
    private var input: AVAudioPCMBuffer?
    private var converter: AVAudioConverter?
    private var rate = 0
    private var channels = 0
    private var frameCount: Int64 = 0
    private var expectedFrames: Int64 = 0
    private var energy = 0.0

    init(turnID: UUID, directory: URL) throws {
        url = directory.appendingPathComponent("capture-\(turnID.uuidString)-\(UUID().uuidString).wav")
        output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false]
        do {
            file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                 ofItemAtPath: url.path)
            try (url as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        } catch {
            file = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func append(samples: UnsafePointer<Float>, frames: Int, channels: Int, sampleRate: Int) throws {
        if input == nil {
            rate = sampleRate
            self.channels = channels
            let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
            input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)
            converter = AVAudioConverter(from: format, to: outputFormat)
            converter?.primeMethod = .none
        }
        guard sampleRate == rate, channels == self.channels,
              let input, let destination = input.floatChannelData?[0], converter != nil else {
            throw RecordingFailure.invalidFile
        }
        input.frameLength = AVAudioFrameCount(frames)
        expectedFrames += Int64(frames) * 16_000 / Int64(sampleRate)
        guard expectedFrames <= 16_000 * 300 else { throw RecordingFailure.invalidFile }
        for frame in 0..<frames {
            var value: Float = 0
            for channel in 0..<channels { value += samples[channel * 480 + frame] }
            value /= Float(channels) * 32768
            guard value.isFinite else { throw RecordingFailure.invalidFile }
            destination[frame] = min(1, max(-1, value))
        }
        try convert(input)
    }

    private func convert(_ input: AVAudioPCMBuffer?) throws {
        guard let converter else { return }
        var supplied = false
        // Bound the loop so a converter that makes no progress cannot stall stop.
        for _ in 0..<16 {
            var error: NSError?
            output.frameLength = 0
            let status = converter.convert(to: output, error: &error) { _, state in
                if let input, !supplied {
                    supplied = true
                    state.pointee = .haveData
                    return input
                }
                state.pointee = input == nil ? .endOfStream : .noDataNow
                return nil
            }
            if let error { throw error }
            guard status != .error else { throw RecordingFailure.invalidFile }
            // A flushed resampler can emit filter-tail frames beyond the input
            // duration. Keep the WAV aligned with the captured turn's clock.
            let count = min(Int(output.frameLength), Int(max(0, expectedFrames - frameCount)))
            if count > 0 {
                guard frameCount + Int64(count) <= 16_000 * 300,
                      let values = output.floatChannelData?[0] else { throw RecordingFailure.invalidFile }
                for index in 0..<count { energy += Double(values[index]) * Double(values[index]) }
                output.frameLength = AVAudioFrameCount(count)
                try file?.write(from: output)
                frameCount += Int64(count)
            }
            if status == .inputRanDry || status == .endOfStream { return }
        }
        throw RecordingFailure.invalidFile
    }

    func finish() throws -> URL {
        try convert(nil) // Flush the converter's tail before closing the WAV.
        file = nil
        clearProcessingBuffers()
        guard frameCount > 0, energy.isFinite, energy > 0 else {
            DiagnosticLog.shared.record("audio.turn_empty", fields: [
                "frames": String(frameCount), "expected_frames": String(expectedFrames),
                "finite_energy": String(energy.isFinite), "has_energy": String(energy > 0)
            ])
            throw RecordingFailure.noAudio
        }
        guard frameCount == expectedFrames else { throw RecordingFailure.invalidFile }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        guard size > 44, size <= 10 * 1024 * 1024 else { throw RecordingFailure.invalidFile }
        DiagnosticLog.shared.record("audio.turn_captured", fields: ["frames": String(frameCount),
            "duration": String(Double(frameCount) / 16_000), "rms": String(sqrt(energy / Double(frameCount)))])
        return url
    }

    func cancel() {
        file = nil
        clearProcessingBuffers()
        try? FileManager.default.removeItem(at: url)
    }

    private func clearProcessingBuffers() {
        if let input, let samples = input.floatChannelData?[0] {
            samples.update(repeating: 0, count: Int(input.frameCapacity))
        }
        output.floatChannelData?[0].update(repeating: 0, count: Int(output.frameCapacity))
        converter?.reset()
        converter = nil
        input = nil
    }
}
