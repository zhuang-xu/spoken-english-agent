import AVFoundation
import Foundation
#if canImport(WebRTC)
import WebRTC

final class NativeRealtimeTransport: NSObject, RealtimeTransporting {
    var onEvent: ((RealtimeEvent) -> Void)?

    private let factory = RTCPeerConnectionFactory()
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
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try audio.setActive(true)
        audioSessionActive = true

        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
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
            let offer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
                peer.offer(for: constraints) { offer, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let offer { continuation.resume(returning: offer) }
                    else { continuation.resume(throwing: RealtimeFailure.invalidAnswer) }
                }
            }
            try await setLocal(offer, on: peer)
            let answer = try await sdp.exchange(offer: offer.sdp, url: url, credential: credential)
            try await setRemote(RTCSessionDescription(type: .answer, sdp: answer), on: peer)
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
            close()
            throw error
        }
    }

    func send(_ payload: [String: Any]) throws {
        guard let channel, channel.readyState == .open else { throw RealtimeFailure.channelUnavailable }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard channel.sendData(RTCDataBuffer(data: data, isBinary: false)) else {
            throw RealtimeFailure.channelUnavailable
        }
    }

    func setInputEnabled(_ enabled: Bool) { inputTrack?.isEnabled = enabled }

    func setSpeakerEnabled(_ enabled: Bool) throws {
        try AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
    }

    func close() {
        guard audioSessionActive || peer != nil || channel != nil || opening != nil else { return }
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
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
        opening?.resume()
        opening = nil
    }

    private func failOpening(_ error: Error) {
        opening?.resume(throwing: error)
        opening = nil
    }
}

extension NativeRealtimeTransport: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.channel === dataChannel else { return }
            if dataChannel.readyState == .open { self.completeOpening() }
            else if dataChannel.readyState == .closed { self.failOpening(RealtimeFailure.channelUnavailable) }
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let event = RealtimeEvent(data: buffer.data) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.channel === dataChannel else { return }
            self.onEvent?(event)
        }
    }
}

extension NativeRealtimeTransport: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed || newState == .closed {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.peer === peerConnection else { return }
                self.onEvent?(RealtimeEvent(type: "transport.closed"))
            }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
#else
// The simulator target remains buildable while the pinned XCFramework cannot be fetched.
// Generate the native project variant to compile this adapter against WebRTC.
final class NativeRealtimeTransport: RealtimeTransporting {
    var onEvent: ((RealtimeEvent) -> Void)?
    func connect(url: URL, credential: String) async throws { throw RealtimeFailure.dependencyUnavailable }
    func send(_ payload: [String: Any]) throws { throw RealtimeFailure.channelUnavailable }
    func setInputEnabled(_ enabled: Bool) {}
    func setSpeakerEnabled(_ enabled: Bool) throws {}
    func close() {}
}
#endif
