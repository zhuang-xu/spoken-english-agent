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
    func start(turnID: UUID) throws
    func stop() throws -> URL
    func cancel()
}

final class WAVTurnRecorder: TurnRecording {
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?

    func start(turnID: UUID) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(turnID.uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let candidate = try AVAudioRecorder(url: url, settings: settings)
        guard candidate.record() else { throw RecordingFailure.couldNotStart }
        recorder = candidate
        fileURL = url
    }

    func stop() throws -> URL {
        guard let recorder, let fileURL else { throw RecordingFailure.notRecording }
        recorder.stop()
        self.recorder = nil
        self.fileURL = nil
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 44, size <= 10 * 1024 * 1024 else { throw RecordingFailure.invalidFile }
        return fileURL
    }

    func cancel() {
        recorder?.stop()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        recorder = nil
        fileURL = nil
    }
}

enum RecordingFailure: Error {
    case couldNotStart
    case notRecording
    case invalidFile
}
