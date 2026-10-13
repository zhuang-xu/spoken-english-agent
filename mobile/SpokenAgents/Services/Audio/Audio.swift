import AVFoundation
import Foundation

protocol MicrophonePermissionProviding {
    func request() async -> Bool
}

struct SystemMicrophonePermission: MicrophonePermissionProviding {
    func request() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }
}

protocol TurnRecording {
    func start(turnID: UUID) async throws
    func stop() async throws -> URL
    func cancel()
}

enum RecordingFailure: Error, Equatable {
    case couldNotStart
    case notRecording
    case invalidFile
    case noAudio
}

struct RecordingEvidence {
    let frames: Int64
    let duration: Double
    let rms: Double

    static func inspect(_ url: URL) throws -> RecordingEvidence {
        let audio = try AVAudioFile(forReading: url)
        guard audio.length > 0 else { throw RecordingFailure.noAudio }
        guard audio.fileFormat.sampleRate == 16_000,
              audio.fileFormat.channelCount == 1 else { throw RecordingFailure.invalidFile }
        let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096)!
        var energy = 0.0
        var count = 0
        while audio.framePosition < audio.length {
            try audio.read(into: buffer)
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else {
                throw RecordingFailure.invalidFile
            }
            for index in 0..<Int(buffer.frameLength) {
                energy += Double(samples[index]) * Double(samples[index])
            }
            count += Int(buffer.frameLength)
        }
        let rms = sqrt(energy / Double(count))
        guard rms.isFinite else { throw RecordingFailure.invalidFile }
        guard rms > 0 else { throw RecordingFailure.noAudio }
        return RecordingEvidence(frames: Int64(count), duration: Double(count) / 16_000, rms: rms)
    }
}
