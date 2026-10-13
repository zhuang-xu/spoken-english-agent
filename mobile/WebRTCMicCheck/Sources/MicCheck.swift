import SwiftUI
import AVFoundation
import WebRTC

@main struct MicCheckApp: App {
    var body: some Scene { WindowGroup { CheckView() } }
}

struct CheckView: View {
    @StateObject private var check = MicCheck()
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("WebRTC microphone check").font(.title)
            Text("Two local peers. No external voice upload. Speak for 15 seconds after capture starts.")
            Text(check.status).font(.headline)
            Text(check.evidence).font(.system(.body, design: .monospaced))
            Button("Start microphone check") { Task { await check.start() } }.disabled(check.running)
            Button("Stop") { check.stop() }.disabled(!check.running)
            Text("A completed sample counter alone is not success. Nonzero source energy verifies a microphone signal reached WebRTC.").font(.footnote)
        }.padding()
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in check.stop() }
    }
}

@MainActor final class MicCheck: NSObject, ObservableObject, RTCPeerConnectionDelegate {
    @Published var status = "Ready"
    @Published var evidence = "No measurement yet"
    @Published var running = false
    private var factory: RTCPeerConnectionFactory?
    private var sender: RTCPeerConnection?
    private var receiver: RTCPeerConnection?
    private var track: RTCAudioTrack?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var peakEnergy = 0.0
    private var snapshots: [[String: String]] = []

    func start() async {
        stop()
        generation = UUID()
        let current = generation
        running = true
        peakEnergy = 0
        snapshots = []
        status = "Requesting microphone permission"
        let allowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard generation == current else { return }
        guard allowed else { running = false; status = "Microphone permission denied"; return }
        do {
            // Persist the valid voice-session configuration before constructing
            // the factory. No forced input route, custom ADM, or processing delegate.
            let config = RTCAudioSessionConfiguration.webRTC()
            config.category = AVAudioSession.Category.playAndRecord.rawValue
            config.mode = AVAudioSession.Mode.voiceChat.rawValue
            config.categoryOptions.insert(.defaultToSpeaker)
            RTCAudioSessionConfiguration.setWebRTC(config)
            RTCInitializeSSL()
            let factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                                   decoderFactory: RTCDefaultVideoDecoderFactory())
            self.factory = factory
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            let configuration = RTCConfiguration()
            configuration.sdpSemantics = .unifiedPlan
            guard let sender = factory.peerConnection(with: configuration, constraints: constraints, delegate: self),
                  let receiver = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
                throw NSError(domain: "MicCheck", code: 1)
            }
            self.sender = sender; self.receiver = receiver
            let source = factory.audioSource(with: constraints)
            let track = factory.audioTrack(with: source, trackId: "demo-microphone")
            self.track = track
            sender.add(track, streamIds: ["demo-stream"])
            status = "Connecting local peers"
            let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { c in
                sender.offer(for: constraints) { s, e in
                    if let s { c.resume(returning: s) } else { c.resume(throwing: e ?? NSError(domain: "SDP", code: 1)) }
                }
            }
            try await set(offer, peer: sender, local: true)
            try await gathered(sender, current: current)
            try await set(sender.localDescription!, peer: receiver, local: false)
            let answer: RTCSessionDescription = try await withCheckedThrowingContinuation { c in
                receiver.answer(for: constraints) { s, e in
                    if let s { c.resume(returning: s) } else { c.resume(throwing: e ?? NSError(domain: "SDP", code: 2)) }
                }
            }
            try await set(answer, peer: receiver, local: true)
            try await gathered(receiver, current: current)
            try await set(receiver.localDescription!, peer: sender, local: false)
            guard generation == current else { return }
            // Avoid acoustic loopback; measurement uses the sender's source stats.
            receiver.receivers.forEach { $0.track?.isEnabled = false }
            status = "Capture active — speak now"
            task = Task { [weak self] in
                for _ in 0..<15 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled, let self, self.generation == current else { return }
                    await self.measure(sender, current: current)
                }
                guard let self, self.generation == current else { return }
                self.status = self.peakEnergy > 0 ? "Nonzero microphone signal detected" : "No microphone energy detected"
                self.stop()
            }
        } catch {
            guard generation == current else { return }
            status = "Setup failed: \((error as NSError).domain) / \((error as NSError).code)"
            stop()
        }
    }

    private func set(_ sdp: RTCSessionDescription, peer: RTCPeerConnection, local: Bool) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let callback: (Error?) -> Void = { e in
                if let e { c.resume(throwing: e) } else { c.resume() }
            }
            if local { peer.setLocalDescription(sdp, completionHandler: callback) }
            else { peer.setRemoteDescription(sdp, completionHandler: callback) }
        }
    }
    private func gathered(_ peer: RTCPeerConnection, current: UUID) async throws {
        for _ in 0..<100 {
            guard generation == current else { throw CancellationError() }
            if peer.iceGatheringState == .complete { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "ICE gathering timeout", code: 1)
    }
    private func measure(_ peer: RTCPeerConnection, current: UUID) async {
        let report = await withCheckedContinuation { c in peer.statistics { c.resume(returning: $0) } }
        guard generation == current else { return }
        var fields: [String: String] = ["time": ISO8601DateFormatter().string(from: Date()),
            "track_enabled": String(track?.isEnabled ?? false), "ice": String(peer.iceConnectionState.rawValue)]
        for stat in report.statistics.values {
            guard (stat.values["kind"] as? String ?? stat.values["mediaType"] as? String) == "audio" else { continue }
            if stat.type == "media-source" {
                for key in ["audioLevel", "totalAudioEnergy", "totalSamplesDuration"] {
                    if let n = stat.values[key] as? NSNumber { fields[key] = n.stringValue }
                }
                if let n = stat.values["totalAudioEnergy"] as? NSNumber { peakEnergy = max(peakEnergy, n.doubleValue) }
            } else if stat.type == "outbound-rtp" {
                for key in ["packetsSent", "bytesSent"] {
                    if let n = stat.values[key] as? NSNumber { fields[key] = n.stringValue }
                }
            }
        }
        let session = AVAudioSession.sharedInstance()
        fields["input"] = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        fields["category"] = session.category.rawValue
        fields["mode"] = session.mode.rawValue
        snapshots.append(fields)
        evidence = ["track_enabled", "ice", "input", "audioLevel", "totalAudioEnergy", "totalSamplesDuration", "packetsSent"].map { "\($0): \(fields[$0] ?? "unavailable")" }.joined(separator: "\n")
    }
    func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        track?.isEnabled = false
        sender?.close(); receiver?.close()
        sender = nil; receiver = nil; track = nil; factory = nil
        running = false
        if !snapshots.isEmpty {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            if let data = try? JSONSerialization.data(withJSONObject: snapshots, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("microphone-metrics.json"), options: .atomic)
            }
        }
    }
    nonisolated func peerConnection(_ p: RTCPeerConnection, didChange s: RTCSignalingState) {}
    nonisolated func peerConnection(_ p: RTCPeerConnection, didAdd s: RTCMediaStream) {}
    nonisolated func peerConnection(_ p: RTCPeerConnection, didRemove s: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ p: RTCPeerConnection) {}
    nonisolated func peerConnection(_ p: RTCPeerConnection, didChange s: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ p: RTCPeerConnection, didChange s: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ p: RTCPeerConnection, didGenerate c: RTCIceCandidate) {}
    nonisolated func peerConnection(_ p: RTCPeerConnection, didRemove c: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ p: RTCPeerConnection, didOpen c: RTCDataChannel) {}
}
