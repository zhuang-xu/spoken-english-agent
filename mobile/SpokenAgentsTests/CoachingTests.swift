import Foundation
import XCTest
@testable import SpokenAgents

@MainActor final class CoachingTests: XCTestCase {
    private let preferences = SessionPreferences(speakingGoal: "Travel speaking", level: "B1",
                                                  preferredTopic: nil, sessionDurationMinutes: 10)
    private let completed = Data("""
    {"status":"completed","result":{"summary":"Keep practicing","grammar":{"score":4,"feedback":"Clear"},
    "vocabulary":{"score":3,"feedback":"Use more varied words"},"coherence":{"score":4,"feedback":"Connected"},
    "strengths":["Clear answers"],"next_steps":["Practice longer turns"],
    "corrections":[{"turn_id":"turn-1","original":"I go","improved":"I went","explanation":"Past tense"}]},
    "speech_summary":null,"not_assessed":["pronunciation","spoken_fluency"]}
    """.utf8)

    private func setup() throws -> (PracticeStore, UUID, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "coaching-\(UUID().uuidString)")
        let store = try PracticeStore(directory: root)
        let id = UUID()
        try store.create(id: id, sessionID: UUID(), key: UUID(), preferences: preferences)
        let turn = UUID()
        try store.queuePayload(id: "transcript/\(turn.uuidString)", practiceID: id,
                               kind: "learnerTranscript", bytes: Data("{\"text\":\"Hello\"}".utf8), contentType: "application/json")
        try store.setStatus("ended", for: id)
        return (store, id, root)
    }

    private func client() -> CoachingClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoachingStub.self]
        return CoachingClient(baseURL: URL(string: "https://example.com")!, session: URLSession(configuration: configuration),
                              maximumPolls: 1, sleep: { _ in })
    }

    func testManifestIsImmutableIncludingMissingIntendedComponents() throws {
        let (store, id, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = UUID()
        try store.savePart(id: missing.uuidString, practiceID: id, speaker: "You", text: "", offsetMilliseconds: 0)
        let original = try store.manifest(for: id)
        let manifest = try JSONDecoder().decode(UploadManifest.self, from: original)
        XCTAssertTrue(manifest.audioTurnIDs.contains(missing.uuidString))
        XCTAssertTrue(manifest.transcriptTurnIDs.contains(missing.uuidString))
        try store.savePart(id: "late/0", practiceID: id, speaker: "Agent", text: "Late", offsetMilliseconds: 1)
        XCTAssertEqual(try store.manifest(for: id), original)
    }

    func testUploadManifestWaitAndCompletedReportSurvivesRelaunch() async throws {
        let (store, id, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        CoachingStub.requests = []
        CoachingStub.evaluations = [
            (202, Data("{\"status\":\"waiting\",\"result\":null,\"not_assessed\":[]}".utf8)),
            (201, completed)
        ]
        CoachingStub.ready = true
        CoachingStub.uploadStatus = 200
        let note = await client().finish(practiceID: id, store: store)
        XCTAssertTrue(note.contains("offline"))
        XCTAssertEqual(store.practices.first?.status, "feedbackReady")
        XCTAssertEqual(CoachingStub.requests.map(\.method), ["PUT", "PUT", "POST", "POST"])
        XCTAssertEqual(CoachingStub.requests.filter { $0.path.hasSuffix("upload-manifest") }.count, 1)
        let reopened = try PracticeStore(directory: root)
        XCTAssertEqual(try JSONDecoder().decode(CoachingResponse.self, from: XCTUnwrap(reopened.practices.first?.reportData)).result?.summary,
                       "Keep practicing")
    }

    func testMissingDataBlocksEvaluation() async throws {
        let (store, id, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        CoachingStub.requests = []
        CoachingStub.ready = false
        CoachingStub.uploadStatus = 200
        let note = await client().finish(practiceID: id, store: store)
        XCTAssertTrue(note.contains("incomplete"))
        XCTAssertEqual(store.practices.first?.status, "incomplete")
        XCTAssertFalse(CoachingStub.requests.contains { $0.path.hasSuffix("evaluation") })
    }

    func testFailedRefreshPreservesCachedReport() async throws {
        let (store, id, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveReport(completed, practiceID: id)
        CoachingStub.evaluations = [(200, Data("{\"status\":\"running\",\"result\":null,\"not_assessed\":[]}".utf8))]
        let note = await client().refresh(practiceID: id, store: store)
        XCTAssertTrue(note.contains("saved report"))
        XCTAssertEqual(store.practices.first?.reportData, completed)
    }

    func testUploadConflictBlocksEvaluationEvenIfServerReportsReady() async throws {
        let (store, id, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        CoachingStub.requests = []
        CoachingStub.ready = true
        CoachingStub.uploadStatus = 409
        let original = try store.bytes(for: XCTUnwrap(store.journal.first))
        let note = await client().finish(practiceID: id, store: store)
        XCTAssertTrue(note.contains("conflicts"))
        XCTAssertEqual(store.practices.first?.status, "incomplete")
        XCTAssertEqual(try store.bytes(for: XCTUnwrap(store.journal.first)), original)
        XCTAssertFalse(CoachingStub.requests.contains { $0.path.hasSuffix("evaluation") })
    }
}

private final class CoachingStub: URLProtocol {
    static var requests: [(method: String, path: String, body: Data?)] = []
    static var evaluations: [(Int, Data)] = []
    static var ready = true
    static var uploadStatus = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.requests.append((request.httpMethod ?? "", path, request.httpBody))
        let status: Int
        let body: Data
        if path.hasSuffix("upload-manifest") {
            status = 200
            body = Data("""
            {"ready_for_evaluation":\(Self.ready ? "true" : "false"),
             "missing":{"audio_turn_ids":[],"transcript_turn_ids":[],"agent_transcripts":[]},
             "unexpected":{"audio_turn_ids":[],"transcript_turn_ids":[],"agent_transcripts":[]}}
            """.utf8)
        } else if path.hasSuffix("evaluation") {
            let next = Self.evaluations.isEmpty ? (500, Data()) : Self.evaluations.removeFirst()
            status = next.0; body = next.1
        } else { status = Self.uploadStatus; body = Data() }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Retry-After": "1"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
