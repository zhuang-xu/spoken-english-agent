import Foundation
import XCTest
@testable import SpokenAgents

@MainActor final class PracticeStoreTests: XCTestCase {
    private let preferences = SessionPreferences(speakingGoal: "Travel speaking", level: "B1",
                                                  preferredTopic: "Airport", sessionDurationMinutes: 10)
    private let report = Data("""
    {"status":"completed","result":{"summary":"Well done","grammar":{"score":4,"feedback":"Clear"},
    "vocabulary":{"score":4,"feedback":"Varied"},"coherence":{"score":4,"feedback":"Connected"},
    "strengths":["Clear answers"],"next_steps":["Practice longer turns"],"corrections":[]},
    "not_assessed":["pronunciation","spoken_fluency"]}
    """.utf8)

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "store-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testRelaunchKeepsOrderConversationReportAndAccountBoundary() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: PracticeStore? = try PracticeStore(directory: root, accountID: "alice")
        let first = UUID(), second = UUID()
        try store?.create(id: first, sessionID: UUID(), key: UUID(), preferences: preferences)
        try store?.savePart(id: "agent-1/0", practiceID: first, speaker: "Agent", text: "Hello", offsetMilliseconds: 10)
        try store?.saveReport(report, practiceID: first)
        try store?.create(id: second, sessionID: UUID(), key: UUID(), preferences: preferences)
        XCTAssertEqual(store?.practices.map(\.id), [second, first])
        store = nil
        let reopened = try PracticeStore(directory: root, accountID: "alice")
        XCTAssertEqual(reopened.practices.map(\.id), [second, first])
        XCTAssertEqual(reopened.parts.first?.text, "Hello")
        XCTAssertNotNil(reopened.practices.first(where: { $0.id == first })?.reportData)
        reopened.switchAccount(to: "bob")
        XCTAssertTrue(reopened.practices.isEmpty)
        XCTAssertTrue(reopened.parts.isEmpty)
        reopened.switchAccount(to: "alice")
        XCTAssertEqual(reopened.practices.count, 2)
    }

    func testJournalPreservesBytesAndDeduplicatesReceipt() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let practice = UUID(), turn = UUID()
        var store: PracticeStore? = try PracticeStore(directory: root)
        try store?.create(id: practice, sessionID: UUID(), key: UUID(), preferences: preferences)
        let payload = Data("{\"text\":\"hello\"}".utf8)
        try store?.queuePayload(id: "transcript/\(turn.uuidString)", practiceID: practice,
                                kind: "learnerTranscript", bytes: payload, contentType: "application/json")
        try store?.queuePayload(id: "transcript/\(turn.uuidString)", practiceID: practice,
                                kind: "learnerTranscript", bytes: payload, contentType: "application/json")
        XCTAssertEqual(store?.journal.count, 1)
        XCTAssertThrowsError(try store?.queuePayload(id: "transcript/\(turn.uuidString)", practiceID: practice,
                                                       kind: "learnerTranscript", bytes: Data("changed".utf8), contentType: "application/json"))
        store = nil
        let reopened = try PracticeStore(directory: root)
        XCTAssertEqual(try reopened.bytes(for: reopened.journal[0]), payload)
        try reopened.markAccepted("transcript/\(turn.uuidString)", practiceID: practice)
        try reopened.markAccepted("transcript/\(turn.uuidString)", practiceID: practice)
        XCTAssertEqual(reopened.journal.count, 1)
        XCTAssertEqual(reopened.journal[0].receipt, "accepted")
    }

    func testMissingAudioRemainsIncompleteAndDeleteRemovesLocalData() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let practice = UUID(), turn = UUID()
        var store: PracticeStore? = try PracticeStore(directory: root)
        try store?.create(id: practice, sessionID: UUID(), key: UUID(), preferences: preferences)
        let source = root.appending(path: "source.wav")
        try Data(repeating: 7, count: 100).write(to: source)
        try store?.queueAudio(turnID: turn, practiceID: practice, source: source)
        let name = try XCTUnwrap(store?.journal.first?.fileName)
        try FileManager.default.removeItem(at: root.appending(path: "Audio/\(name)"))
        store = nil
        let reopened = try PracticeStore(directory: root)
        XCTAssertEqual(reopened.practices.first?.status, "incomplete")
        XCTAssertNotNil(reopened.journal.first?.issue)
        try reopened.delete(practice)
        XCTAssertTrue(reopened.practices.isEmpty)
        XCTAssertTrue(reopened.journal.isEmpty)
    }

    func testOrphanedAudioMoveIsRecoveredOnLaunch() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let practice = UUID(), turn = UUID()
        var store: PracticeStore? = try PracticeStore(directory: root)
        try store?.create(id: practice, sessionID: UUID(), key: UUID(), preferences: preferences)
        store = nil
        let audio = root.appending(path: "Audio/\(practice.uuidString)-\(turn.uuidString).wav")
        try Data(repeating: 2, count: 100).write(to: audio)
        let reopened = try PracticeStore(directory: root)
        XCTAssertEqual(reopened.journal.first?.id, "audio/\(turn.uuidString)")
        XCTAssertEqual(try reopened.bytes(for: try XCTUnwrap(reopened.journal.first)).count, 100)
        XCTAssertEqual(reopened.practices.first?.status, "incomplete")
    }

    func testCorruptCachedReportKeepsConversationIncomplete() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PracticeStore(directory: root)
        let practice = UUID()
        try store.create(id: practice, sessionID: UUID(), key: UUID(), preferences: preferences)
        try store.savePart(id: "agent-1/0", practiceID: practice, speaker: "Agent", text: "Hello", offsetMilliseconds: 1)
        try store.saveReport(report, practiceID: practice)
        store.practices[0].reportData = Data("broken".utf8)
        store.reconcile()
        XCTAssertEqual(store.practices[0].status, "incomplete")
        XCTAssertNil(store.practices[0].reportData)
        XCTAssertEqual(store.parts.first?.text, "Hello")
    }

    func testRetryUsesExactBytesAnd409KeepsPendingPayload() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PracticeStore(directory: root)
        let practice = UUID(), turn = UUID()
        try store.create(id: practice, sessionID: UUID(), key: UUID(), preferences: preferences)
        let payload = Data("{\"text\":\"exact bytes\"}".utf8)
        let id = "transcript/\(turn.uuidString)"
        try store.queuePayload(id: id, practiceID: practice, kind: "learnerTranscript",
                               bytes: payload, contentType: "application/json")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadStub.self]
        let session = URLSession(configuration: config)
        UploadStub.status = 409
        UploadStub.body = nil
        let client = UploadJournalClient(baseURL: URL(string: "https://example.com")!, session: session)
        let rejected = await client.retry(practiceID: practice, store: store)
        XCTAssertEqual(rejected, 0)
        XCTAssertEqual(UploadStub.body, payload)
        XCTAssertEqual(store.journal.first?.receipt, "pending")
        XCTAssertEqual(try store.bytes(for: try XCTUnwrap(store.journal.first)), payload)
        UploadStub.status = 200
        let accepted = await client.retry(practiceID: practice, store: store)
        XCTAssertEqual(accepted, 1)
        XCTAssertEqual(UploadStub.body, payload)
        XCTAssertEqual(store.journal.first?.receipt, "accepted")
    }
}

private final class UploadStub: URLProtocol {
    static var status = 200
    static var body: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let body = request.httpBody { Self.body = body }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            Self.body = bytes
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
