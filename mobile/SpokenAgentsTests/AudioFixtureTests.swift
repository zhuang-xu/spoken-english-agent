import AVFoundation
import XCTest
@testable import SpokenAgents

final class AudioFixtureTests: XCTestCase {
    func testSixteenKilohertzMonoWAVFixtureDecodes() throws {
        let samples = 16_000
        let pcmBytes = samples * 2
        var wav = Data()
        wav.append(contentsOf: "RIFF".utf8)
        wav.appendLE(UInt32(36 + pcmBytes))
        wav.append(contentsOf: "WAVEfmt ".utf8)
        wav.appendLE(UInt32(16))
        wav.appendLE(UInt16(1))
        wav.appendLE(UInt16(1))
        wav.appendLE(UInt32(16_000))
        wav.appendLE(UInt32(32_000))
        wav.appendLE(UInt16(2))
        wav.appendLE(UInt16(16))
        wav.append(contentsOf: "data".utf8)
        wav.appendLE(UInt32(pcmBytes))
        wav.append(Data(repeating: 0, count: pcmBytes))

        let url = FileManager.default.temporaryDirectory.appending(path: "fixture-\(UUID().uuidString).wav")
        try wav.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoded = try AVAudioFile(forReading: url)
        XCTAssertEqual(decoded.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(decoded.fileFormat.channelCount, 1)
        XCTAssertEqual(decoded.length, AVAudioFramePosition(samples))
        XCTAssertLessThan(wav.count, 10 * 1024 * 1024)
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
