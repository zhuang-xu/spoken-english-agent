import AVFoundation
import Foundation
import Synchronization
#if canImport(WebRTC)
import WebRTC

final class NativeRealtimeTransport: NSObject, RealtimeTransporting {
    var onEvent: ((RealtimeEvent) -> Void)?

    private let capture: WebRTCAudioCapture
    private let outputDiagnostics = WebRTCOutputDiagnostics()
    private var mediaDiagnosticsTimer: Timer?
    private let processing: RTCDefaultAudioProcessingModule
    private let factory: RTCPeerConnectionFactory
    private let audioDiagnostics = WebRTCAudioSessionDiagnostics()
    private let factoryID = UUID().uuidString
    #if DEBUG
    private var nativeLogger: RTCFileLogger?
    #endif

    init(capture: WebRTCAudioCapture = WebRTCAudioCapture()) {
        self.capture = capture
        processing = Self.makeAudioProcessingModule(capture: capture, render: outputDiagnostics)
        factory = RTCPeerConnectionFactory(audioDeviceModuleType: .platformDefault,
            bypassVoiceProcessing: false,
            encoderFactory: nil, decoderFactory: nil, audioProcessingModule: processing)
        super.init()
        DiagnosticLog.shared.record("rtc.factory_created", fields: ["factory": factoryID])
    }

    static func makeAudioProcessingModule(
        capture: RTCAudioCustomProcessingDelegate,
        render: RTCAudioCustomProcessingDelegate
    ) -> RTCDefaultAudioProcessingModule {
        let module = RTCDefaultAudioProcessingModule(config: nil,
            capturePostProcessingDelegate: nil, renderPreProcessingDelegate: nil)
        // SDK 150.7871.01's adapter initializer ignores its delegate argument.
        // The setters call SetDelegate on the native adapters, attaching callbacks
        // (and replaying format initialization if processing has already started).
        module.capturePostProcessingDelegate = capture
        module.renderPreProcessingDelegate = render
        return module
    }

    deinit {
        DiagnosticLog.shared.record("rtc.factory_released", fields: ["factory": factoryID])
    }

    private var peer: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var inputTrack: RTCAudioTrack?
    private var opening: CheckedContinuation<Void, Error>?
    private var generation = UUID()
    private var audioSessionActive = false
    private let sdp = HTTPSDPExchanger()

    func connect(url: URL, credential: String) async throws {
        close()
        #if DEBUG
        if ProcessInfo.processInfo.environment["PHYSICAL_AUDIO_DIAGNOSTICS"] == "1" {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("NativeAudioDiagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var protectedDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try protectedDirectory.setResourceValues(values)
            let logger = RTCFileLogger(dirPath: directory.path, maxFileSize: 1_000_000)
            logger.severity = .info
            logger.shouldDisableBuffering = true
            logger.start()
            nativeLogger = logger
        }
        #endif
        let current = generation
        DiagnosticLog.shared.record("rtc.connect", fields: ["transport": current.uuidString])
        let audio = RTCAudioSession.sharedInstance()
        DiagnosticLog.shared.record("audio.activate_start")
        // WebRTC reapplies its own configuration when its audio unit starts.
        // Keep speaker routing in that configuration, not just the initial AVAudioSession.
        let rtcConfiguration = RTCAudioSessionConfiguration.webRTC()
        // This SDK seeds category/mode from AVAudioSession when first loaded,
        // which can be SoloAmbient/Default before a call. Persist voice settings
        // too, so native audio-device startup does not reapply an invalid mix.
        rtcConfiguration.category = AVAudioSession.Category.playAndRecord.rawValue
        rtcConfiguration.mode = AVAudioSession.Mode.voiceChat.rawValue
        rtcConfiguration.categoryOptions.insert(.defaultToSpeaker)
        rtcConfiguration.categoryOptions.remove(.allowBluetoothHFP)
        RTCAudioSessionConfiguration.setWebRTC(rtcConfiguration)
        audio.lockForConfiguration()
        do {
            defer { audio.unlockForConfiguration() }
            try audio.setCategory(.playAndRecord, mode: .voiceChat,
                                  options: rtcConfiguration.categoryOptions)
            try audio.setActive(true)
            audioSessionActive = true
            if let microphone = audio.session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try audio.setPreferredInput(microphone)
            }
            try audio.overrideOutputAudioPort(.speaker)
        } catch {
            close()
            throw error
        }
        DiagnosticLog.shared.record("audio.activated", fields: ["sample_rate": String(audio.sampleRate),
            "input_channels": String(audio.inputNumberOfChannels), "output_channels": String(audio.outputNumberOfChannels)])
        recordAudioRoute("audio.route_activated")

        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            close()
            throw RealtimeFailure.channelUnavailable
        }
        self.peer = peer
        let source = factory.audioSource(with: constraints)
        let track = factory.audioTrack(with: source, trackId: "learner-audio")
        track.isEnabled = false
        inputTrack = track
        peer.add(track, streamIds: ["spoken-agents"])
        let channel = peer.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration())
        guard let channel else { close(); throw RealtimeFailure.channelUnavailable }
        self.channel = channel
        channel.delegate = self

        do {
            DiagnosticLog.shared.record("rtc.offer_start")
            let offer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
                peer.offer(for: constraints) { offer, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let offer { continuation.resume(returning: offer) }
                    else { continuation.resume(throwing: RealtimeFailure.invalidAnswer) }
                }
            }
            guard generation == current else { throw CancellationError() }
            DiagnosticLog.shared.record("rtc.offer_created")
            try await setLocal(offer, on: peer)
            guard generation == current else { throw CancellationError() }
            DiagnosticLog.shared.record("rtc.local_description_set")
            let answer = try await sdp.exchange(offer: offer.sdp, url: url, credential: credential)
            guard generation == current else { throw CancellationError() }
            DiagnosticLog.shared.record("rtc.answer_received")
            try await setRemote(RTCSessionDescription(type: .answer, sdp: answer), on: peer)
            DiagnosticLog.shared.record("rtc.remote_description_set")
            guard generation == current else { throw CancellationError() }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                opening = continuation
                if channel.readyState == .open { completeOpening() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                    guard let self, self.generation == current else { return }
                    self.failOpening(RealtimeFailure.connectionTimedOut)
                }
            }
        } catch {
            DiagnosticLog.shared.failure("rtc.connect_failure", error: error, fields: ["transport": current.uuidString])
            if generation == current { close() }
            throw error
        }
    }

    func send(_ payload: [String: Any]) throws {
        if let type = payload["type"] as? String { DiagnosticLog.shared.record("rtc.send", fields: ["type": type]) }
        guard let channel, channel.readyState == .open else { throw RealtimeFailure.channelUnavailable }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard channel.sendData(RTCDataBuffer(data: data, isBinary: false)) else {
            throw RealtimeFailure.channelUnavailable
        }
    }

    func setInputEnabled(_ enabled: Bool) { inputTrack?.isEnabled = enabled }

    func startInput() throws {
        guard let track = inputTrack, peer != nil else { throw RealtimeFailure.channelUnavailable }
        let device = factory.audioDeviceModule
        let wasMuted = processing.isMuted
        processing.isMuted = false
        // Keep init/start separate so initialization failures cannot be hidden
        // by the SDK convenience method's platform-default implementation.
        let initializeResult = device.isRecordingInitialized ? 0 : device.initRecording()
        var startResult = 0
        if initializeResult == 0 {
            startResult = device.recording ? 0 : device.startRecording()
        }
        let deviceMuted = device.isMicrophoneMuted
        var unmuteResult = 0
        if deviceMuted { unmuteResult = device.setMicrophoneMuted(false) }
        let ready = initializeResult == 0 && startResult == 0 && unmuteResult == 0
            && device.isRecordingInitialized && device.recording
            && !processing.isMuted && !device.isMicrophoneMuted
        track.isEnabled = ready
        let audio = RTCAudioSession.sharedInstance()
        DiagnosticLog.shared.record("audio.input_start", fields: [
            "init_result": String(initializeResult), "start_result": String(startResult),
            "unmute_result": String(unmuteResult), "processing_was_muted": String(wasMuted),
            "processing_muted": String(processing.isMuted),
            "device_was_muted": String(deviceMuted), "device_muted": String(device.isMicrophoneMuted),
            "recording_initialized": String(device.isRecordingInitialized),
            "recording": String(device.recording), "track_enabled": String(track.isEnabled),
            "manual_audio": String(audio.useManualAudio), "audio_enabled": String(audio.isAudioEnabled)
        ])
        guard ready, track.isEnabled else { throw RealtimeFailure.microphoneStartupFailed }
    }

    func setSpeakerEnabled(_ enabled: Bool) throws {
        let audio = RTCAudioSession.sharedInstance()
        let configuration = RTCAudioSessionConfiguration.webRTC()
        configuration.category = AVAudioSession.Category.playAndRecord.rawValue
        configuration.mode = AVAudioSession.Mode.voiceChat.rawValue
        if enabled {
            configuration.categoryOptions.insert(.defaultToSpeaker)
            configuration.categoryOptions.remove(.allowBluetoothHFP)
        } else {
            configuration.categoryOptions.remove(.defaultToSpeaker)
            configuration.categoryOptions.insert(.allowBluetoothHFP)
        }
        audio.lockForConfiguration()
        defer { audio.unlockForConfiguration() }
        try audio.setCategory(.playAndRecord, mode: .voiceChat,
                              options: configuration.categoryOptions)
        if enabled {
            if let microphone = audio.session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try audio.setPreferredInput(microphone)
            }
        } else {
            // M137 marks the proxy argument nonnull; reset Apple's optional
            // preference under the same WebRTC configuration lock.
            try audio.session.setPreferredInput(nil)
        }
        try audio.overrideOutputAudioPort(enabled ? .speaker : .none)
        RTCAudioSessionConfiguration.setWebRTC(configuration)
        recordAudioRoute("audio.route_selected", fields: ["speaker_requested": String(enabled)])
    }

    func close() {
        capture.cancel()
        guard audioSessionActive || peer != nil || channel != nil || opening != nil else { return }
        DiagnosticLog.shared.record("rtc.close", fields: ["transport": generation.uuidString])
        mediaDiagnosticsTimer?.invalidate()
        mediaDiagnosticsTimer = nil
        outputDiagnostics.recordSnapshot()
        generation = UUID()
        failOpening(CancellationError())
        inputTrack?.isEnabled = false
        channel?.delegate = nil
        channel?.close()
        peer?.close()
        channel = nil
        peer = nil
        inputTrack = nil
        if audioSessionActive {
            audioSessionActive = false
            let audio = RTCAudioSession.sharedInstance()
            audio.lockForConfiguration()
            defer { audio.unlockForConfiguration() }
            try? audio.setActive(false)
        }
        #if DEBUG
        nativeLogger?.stop()
        nativeLogger = nil
        #endif
    }

    private func setLocal(_ description: RTCSessionDescription, on peer: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func setRemote(_ description: RTCSessionDescription, on peer: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func completeOpening() {
        DiagnosticLog.shared.record("rtc.channel_open")
        opening?.resume()
        opening = nil
        recordMediaDiagnostics()
        let current = generation
        mediaDiagnosticsTimer?.invalidate()
        mediaDiagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            // Scheduled from the main actor, so this timer fires on the main run loop.
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { timer.invalidate(); return }
                self.recordMediaDiagnostics()
            }
        }
    }

    private func recordMediaDiagnostics() {
        guard let peer else { return }
        outputDiagnostics.recordSnapshot()
        capture.recordDiagnostics()
        var receiverCount = 0
        for receiver in peer.receivers {
            guard let track = receiver.track, track.kind == "audio" else { continue }
            receiverCount += 1
            DiagnosticLog.shared.record("rtc.audio_receiver", fields: [
                "transport": generation.uuidString, "enabled": String(track.isEnabled),
                "state": String(track.readyState.rawValue)])
        }
        DiagnosticLog.shared.record("rtc.audio_receiver_count", fields: [
            "transport": generation.uuidString, "count": String(receiverCount)])
        let audio = RTCAudioSession.sharedInstance()
        recordAudioRoute("audio.route_snapshot", fields: ["transport": generation.uuidString])
        DiagnosticLog.shared.record("audio.media_state", fields: [
            "factory": factoryID,
            "playout_initialized": String(factory.audioDeviceModule.isPlayoutInitialized),
            "recording_initialized": String(factory.audioDeviceModule.isRecordingInitialized),
            "active": String(audio.isActive), "manual": String(audio.useManualAudio),
            "enabled": String(audio.isAudioEnabled), "volume": String(audio.outputVolume),
            "playing": String(factory.audioDeviceModule.playing),
            "recording": String(factory.audioDeviceModule.recording),
            "input": audio.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ","),
            "output": audio.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")])
        let current = generation
        peer.statistics { [weak self] report in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                var audioReports = 0
                var inboundReports = 0
                for stat in report.statistics.values where ["inbound-rtp", "outbound-rtp", "media-source", "media-playout"].contains(stat.type) {
                    guard (stat.values["kind"] as? String ?? stat.values["mediaType"] as? String) == "audio" else { continue }
                    audioReports += 1
                    if stat.type == "inbound-rtp" { inboundReports += 1 }
                    var fields = ["direction": stat.type, "stats_id": stat.id, "transport": current.uuidString]
                    for key in ["packetsReceived", "bytesReceived", "packetsSent", "bytesSent",
                                "packetsLost", "totalAudioEnergy", "totalSamplesReceived", "totalSamplesDuration",
                                "audioLevel", "jitter", "jitterBufferDelay", "jitterBufferEmittedCount",
                                "concealedSamples", "silentConcealedSamples", "concealmentEvents",
                                "insertedSamplesForDeceleration", "removedSamplesForAcceleration",
                                "totalPlayoutDelay", "totalSamplesCount", "synthesizedSamplesDuration",
                                "synthesizedSamplesEvents"] {
                        if let value = stat.values[key] as? NSNumber { fields[key] = value.stringValue }
                    }
                    DiagnosticLog.shared.record("rtc.audio_stats", fields: fields)
                }
                DiagnosticLog.shared.record("rtc.audio_stats_report", fields: [
                    "transport": current.uuidString, "audio_reports": String(audioReports),
                    "inbound_reports": String(inboundReports)])
            }
        }
    }

    private func failOpening(_ error: Error) {
        if opening != nil { DiagnosticLog.shared.failure("rtc.channel_open_failure", error: error) }
        opening?.resume(throwing: error)
        opening = nil
    }
}

extension NativeRealtimeTransport: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let identity = ObjectIdentifier(dataChannel)
        DispatchQueue.main.async { [weak self] in
            guard let self, let dataChannel = self.channel, ObjectIdentifier(dataChannel) == identity else { return }
            DiagnosticLog.shared.record("rtc.channel_state", fields: ["state": String(dataChannel.readyState.rawValue)])
            if dataChannel.readyState == .open { self.completeOpening() }
            else if dataChannel.readyState == .closed { self.failOpening(RealtimeFailure.channelUnavailable) }
        }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let event = RealtimeEvent(data: buffer.data) else { return }
        let identity = ObjectIdentifier(dataChannel)
        DispatchQueue.main.async { [weak self] in
            guard let self, let channel = self.channel, ObjectIdentifier(channel) == identity else { return }
            self.onEvent?(event)
        }
    }
}

extension NativeRealtimeTransport: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        DiagnosticLog.shared.record("rtc.signaling_state", fields: ["state": String(stateChanged.rawValue)])
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DiagnosticLog.shared.record("rtc.ice_state", fields: ["state": String(newState.rawValue)])
        if newState == .failed || newState == .closed {
            let identity = ObjectIdentifier(peerConnection)
            DispatchQueue.main.async { [weak self] in
                guard let self, let peer = self.peer, ObjectIdentifier(peer) == identity else { return }
                self.onEvent?(RealtimeEvent(type: "transport.closed"))
            }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        DiagnosticLog.shared.record("rtc.ice_gathering", fields: ["state": String(newState.rawValue)])
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
/// Retained for the transport lifetime; session delegates are weak references.
/// Reports device lifecycle metadata without audio or conversation payloads.
private final class WebRTCAudioSessionDiagnostics: NSObject, RTCAudioSessionDelegate {
    override init() {
        super.init()
        RTCAudioSession.sharedInstance().add(self)
    }
    deinit { RTCAudioSession.sharedInstance().remove(self) }

    func audioSessionDidStartPlayOrRecord(_ session: RTCAudioSession) {
        DiagnosticLog.shared.record("audio.device_started")
        recordAudioRoute("audio.route_device_started")
    }
    func audioSessionDidStopPlayOrRecord(_ session: RTCAudioSession) {
        DiagnosticLog.shared.record("audio.device_stopped")
    }
    func audioSession(_ session: RTCAudioSession, didChangeCanPlayOrRecord canPlayOrRecord: Bool) {
        DiagnosticLog.shared.record("audio.device_allowed", fields: ["allowed": String(canPlayOrRecord)])
    }
    func audioSession(_ session: RTCAudioSession, audioUnitStartFailedWithError error: Error) {
        DiagnosticLog.shared.failure("audio.device_start_failed", error: error)
    }
}

/// Read actual hardware routing as well as configuration; omit device names/IDs.
private func recordAudioRoute(_ event: String, fields: [String: String] = [:]) {
    let audio = AVAudioSession.sharedInstance()
    var metadata = fields
    metadata["category"] = audio.category.rawValue
    metadata["mode"] = audio.mode.rawValue
    metadata["category_options"] = String(audio.categoryOptions.rawValue)
    metadata["input"] = audio.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
    metadata["output"] = audio.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
    metadata["sample_rate"] = String(audio.sampleRate)
    metadata["io_buffer_duration"] = String(audio.ioBufferDuration)
    metadata["input_channels"] = String(audio.inputNumberOfChannels)
    metadata["output_channels"] = String(audio.outputNumberOfChannels)
    metadata["output_volume"] = String(audio.outputVolume)
    DiagnosticLog.shared.record(event, fields: metadata)
}
#else
// The simulator target remains buildable while the pinned XCFramework cannot be fetched.
// Generate the native project variant to compile this adapter against WebRTC.
final class NativeRealtimeTransport: RealtimeTransporting {
    init(capture: WebRTCAudioCapture = WebRTCAudioCapture()) {}
    var onEvent: ((RealtimeEvent) -> Void)?
    func connect(url: URL, credential: String) async throws { throw RealtimeFailure.dependencyUnavailable }
    func send(_ payload: [String: Any]) throws { throw RealtimeFailure.channelUnavailable }
    func setInputEnabled(_ enabled: Bool) {}
    func startInput() throws { throw RealtimeFailure.dependencyUnavailable }
    func setSpeakerEnabled(_ enabled: Bool) throws {}
    func close() {}
}
#endif

#if canImport(WebRTC)
/// Observes render PCM without retaining or modifying audio. Atomic counters keep
/// logging and file I/O off WebRTC's audio thread. Values are lifetime cumulative.
final class WebRTCOutputDiagnostics: NSObject, RTCAudioCustomProcessingDelegate {
    private let stage: String
    init(stage: String = "render_pre_processing") {
        self.stage = stage
        super.init()
    }

    private let callbacks = Atomic<Int>(0)
    private let frames = Atomic<Int>(0)
    private let samples = Atomic<Int>(0)
    private let nonzeroSamples = Atomic<Int>(0)
    private let energyMillionths = Atomic<Int>(0)
    private let peakMillionths = Atomic<Int>(0)
    private let rate = Atomic<Int>(0)
    private let channels = Atomic<Int>(0)

    func audioProcessingInitialize(sampleRate: Int, channels: Int) {
        rate.store(sampleRate, ordering: .relaxed)
        self.channels.store(channels, ordering: .relaxed)
    }

    func audioProcessingProcess(audioBuffer: RTCAudioBuffer) {
        observe(frames: audioBuffer.frames, channels: audioBuffer.channels) {
            UnsafePointer(audioBuffer.rawBuffer(forChannel: $0))
        }
    }

    func observe(frames frameCount: Int, channels channelCount: Int,
                 channelData: (Int) -> UnsafePointer<Float>) {
        guard frameCount > 0, channelCount > 0 else { return }
        var nonzero = 0
        var energy = 0.0
        var peak = 0.0
        for channel in 0..<channelCount {
            let buffer = channelData(channel)
            for frame in 0..<frameCount {
                // WebRTC exposes FloatS16, so normalize to full scale.
                let value = Double(buffer[frame]) / 32768.0
                guard value.isFinite else { continue }
                if value != 0 { nonzero += 1 }
                energy += value * value
                peak = max(peak, abs(value))
            }
        }
        callbacks.wrappingAdd(1, ordering: .relaxed)
        frames.wrappingAdd(frameCount, ordering: .relaxed)
        samples.wrappingAdd(frameCount * channelCount, ordering: .relaxed)
        nonzeroSamples.wrappingAdd(nonzero, ordering: .relaxed)
        energyMillionths.wrappingAdd(Int(min(energy * 1_000_000, Double(Int.max / 2))), ordering: .relaxed)
        peakMillionths.store(Int(min(peak * 1_000_000, Double(Int.max / 2))), ordering: .relaxed)
    }

    func audioProcessingRelease() {}

    func recordSnapshot() {
        DiagnosticLog.shared.record(stage == "render_pre_processing" ? "audio.output_pcm_stats" : "audio.input_pcm_stats", fields: snapshotFields())
    }

    func snapshotFields() -> [String: String] {
        let count = samples.load(ordering: .relaxed)
        let energy = Double(energyMillionths.load(ordering: .relaxed)) / 1_000_000
        return [
            "scope": "factory_lifetime", "stage": stage,
            "callbacks": String(callbacks.load(ordering: .relaxed)),
            "frames": String(frames.load(ordering: .relaxed)), "samples": String(count),
            "nonzero_samples": String(nonzeroSamples.load(ordering: .relaxed)),
            "sample_rate": String(rate.load(ordering: .relaxed)),
            "channels": String(channels.load(ordering: .relaxed)),
            "rms": String(count > 0 ? sqrt(energy / Double(count)) : 0),
            "latest_buffer_peak": String(Double(peakMillionths.load(ordering: .relaxed)) / 1_000_000)]
    }
}
#endif
