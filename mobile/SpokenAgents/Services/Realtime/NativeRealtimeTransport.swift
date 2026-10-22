import AVFoundation
import Foundation
#if canImport(WebRTC)
import WebRTC

final class NativeRealtimeTransport: NSObject, RealtimeTransporting {
    var onEvent: ((RealtimeEvent) -> Void)?

    private let capture: WebRTCAudioCapture
    private let processing: RTCDefaultAudioProcessingModule
    private let factory: RTCPeerConnectionFactory
    private let audioDiagnostics = WebRTCAudioSessionDiagnostics()
    private let factoryID = UUID().uuidString

    init(capture: WebRTCAudioCapture = WebRTCAudioCapture()) {
        self.capture = capture
        processing = Self.makeAudioProcessingModule(capture: capture)
        factory = RTCPeerConnectionFactory(audioDeviceModuleType: .platformDefault,
            bypassVoiceProcessing: false,
            encoderFactory: nil, decoderFactory: nil, audioProcessingModule: processing)
        super.init()
        DiagnosticLog.shared.record("rtc.factory_created", fields: ["factory": factoryID])
    }

    static func makeAudioProcessingModule(
        capture: RTCAudioCustomProcessingDelegate
    ) -> RTCDefaultAudioProcessingModule {
        let module = RTCDefaultAudioProcessingModule(config: nil,
            capturePostProcessingDelegate: nil, renderPreProcessingDelegate: nil)
        // SDK 150.7871.01's adapter initializer ignores its delegate argument.
        // The setters call SetDelegate on the native adapters, attaching callbacks
        // (and replaying format initialization if processing has already started).
        module.capturePostProcessingDelegate = capture
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
