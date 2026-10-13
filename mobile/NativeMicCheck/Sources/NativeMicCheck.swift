import SwiftUI
import AVFoundation

@main struct NativeMicCheckApp: App {
    var body: some Scene { WindowGroup { MicrophoneView() } }
}

struct MicrophoneView: View {
    @StateObject private var test = NativeMicrophoneTest()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Native microphone check").font(.title)
            Text("No WebRTC. No network. No voice recording saved.")
            Text("Tap Start, allow microphone access, then speak for 15 seconds.")
            Text(test.status).font(.headline)
            Text(test.metrics).font(.system(.body, design: .monospaced))
            Button("Start native capture") { Task { await test.start() } }.disabled(test.running)
            Button("Stop") { test.stop() }.disabled(!test.running)
            Text("Uses a record/measurement audio session without voice processing. A nonzero signal verifies input, not speech recognition.").font(.footnote)
        }.padding()
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in test.stop() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
            test.stop(reason: "Audio session interrupted")
        }
    }
}

private final class InputMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks = 0, frames = 0, samples = 0, nonzero = 0, unsupported = 0
    private var energy = 0.0, peak = 0.0, sampleRate = 0.0
    private var channels = 0, commonFormat = 0
    func receive(_ buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        var count = 0, nz = 0
        var sum = 0.0, maxValue = 0.0
        for channel in 0..<channelCount {
            for frame in 0..<frameCount {
                let plane = interleaved ? 0 : channel
                let index = interleaved ? frame * channelCount + channel : frame
                let value: Double
                if let data = buffer.floatChannelData { value = Double(data[plane][index]) }
                else if let data = buffer.int16ChannelData { value = Double(data[plane][index]) / 32768.0 }
                else if let data = buffer.int32ChannelData { value = Double(data[plane][index]) / 2147483648.0 }
                else { continue }
                guard value.isFinite else { continue }
                count += 1; if value != 0 { nz += 1 }
                sum += value * value; maxValue = max(maxValue, abs(value))
            }
        }
        // Never wait on the audio callback; snapshots hold the lock briefly.
        guard lock.try() else { return }
        callbacks += 1; frames += frameCount; samples += count; nonzero += nz
        energy += sum; peak = max(peak, maxValue)
        sampleRate = buffer.format.sampleRate; channels = channelCount
        commonFormat = Int(buffer.format.commonFormat.rawValue)
        if frameCount > 0 && count == 0 { unsupported += 1 }
        lock.unlock()
    }
    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["callbacks": callbacks, "frames": frames, "samples": samples,
                "nonzero_samples": nonzero, "energy": energy, "peak": peak,
                "rms": samples > 0 ? sqrt(energy / Double(samples)) : 0,
                "sample_rate": sampleRate, "channels": channels,
                "common_format": commonFormat, "unsupported_buffers": unsupported]
    }
}

@MainActor final class NativeMicrophoneTest: ObservableObject {
    @Published var status = "Ready"
    @Published var metrics = "No measurement yet"
    @Published var running = false
    private var engine: AVAudioEngine?
    private var collector = InputMetrics()
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var snapshots: [[String: Any]] = []
    private var started: Date?

    func start() async {
        stop()
        generation = UUID()
        let current = generation
        collector = InputMetrics(); snapshots = []; started = nil
        running = true; status = "Requesting microphone permission"
        let allowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard generation == current else { return }
        guard allowed else { stop(reason: "Microphone permission denied"); return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(domain: "Invalid microphone format", code: 1)
            }
            let collector = self.collector
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in collector.receive(buffer) }
            engine.prepare()
            try engine.start()
            started = Date()
            status = "Native capture active — speak now"
            task = Task { [weak self] in
                for _ in 0..<15 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled, let self, self.generation == current else { return }
                    self.measure()
                }
                guard let self, self.generation == current else { return }
                self.stop()
            }
        } catch {
            let e = error as NSError
            snapshots.append(["error_domain": e.domain, "error_code": e.code])
            stop(reason: "Capture failed: \(e.domain) / \(e.code)")
        }
    }
    private func measure() {
        var fields = collector.snapshot()
        let session = AVAudioSession.sharedInstance()
        fields["time"] = ISO8601DateFormatter().string(from: Date())
        fields["elapsed"] = started.map { Date().timeIntervalSince($0) } ?? 0
        fields["category"] = session.category.rawValue
        fields["mode"] = session.mode.rawValue
        fields["input"] = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        fields["input_channels"] = session.inputNumberOfChannels
        fields["engine_running"] = engine?.isRunning ?? false
        snapshots.append(fields)
        metrics = ["callbacks", "frames", "nonzero_samples", "rms", "peak", "sample_rate", "channels", "input"].map {
            "\($0): \(fields[$0].map { String(describing: $0) } ?? "unavailable")"
        }.joined(separator: "\n")
    }
    func stop(reason: String? = nil) {
        let wasRunning = running
        generation = UUID(); task?.cancel(); task = nil
        if engine != nil { measure() }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop(); engine = nil
        if wasRunning { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        running = false
        let result = collector.snapshot()
        if let reason { status = reason }
        else if wasRunning {
            if (result["callbacks"] as? Int ?? 0) == 0 { status = "No native input callbacks received" }
            else if (result["unsupported_buffers"] as? Int ?? 0) > 0 { status = "Buffer format requires inspection" }
            else { status = (result["nonzero_samples"] as? Int ?? 0) > 0 ? "Nonzero native input detected" : "Native input samples are zero" }
        }
        guard !snapshots.isEmpty else { return }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let report: [String: Any] = ["status": status, "summary": result, "snapshots": snapshots]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("native-microphone-metrics.json"), options: .atomic)
        }
    }
}
