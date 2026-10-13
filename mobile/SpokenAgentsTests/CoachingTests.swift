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

    override func setUp() {
        super.setUp()
        CoachingStub.requests = []
        CoachingStub.evaluations = []
        CoachingStub.ready = true
        CoachingStub.uploadStatus = 200
        CoachingStub.retryAfter = "1"
    }

    func testRejectedAudioStopsRetriesAndCannotRequestFeedback() async throws {
        let (store, id, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let turn = UUID()
        let audio = root.appending(path: "source.wav")
        try Data(repeating: 0, count: 100).write(to: audio)
        try store.queueAudio(turnID: turn, practiceID: id, source: audio)
        CoachingStub.uploadStatus = 422
        let coaching = client()
        let note = await coaching.finish(practiceID: id, store: store)
        XCTAssertTrue(note.contains("Start a new practice"))
        XCTAssertEqual(store.journal.first { $0.kind == "audio" }?.receipt, "rejected")
        XCTAssertFalse(CoachingStub.requests.contains { $0.path.hasSuffix("evaluation") })
        let attemptedAudio = CoachingStub.requests.filter { $0.path.hasSuffix("audio") }.count
        _ = await coaching.finish(practiceID: id, store: store)
        XCTAssertEqual(CoachingStub.requests.filter { $0.path.hasSuffix("audio") }.count, attemptedAudio)
        let reopened = try PracticeStore(directory: root)
        XCTAssertEqual(reopened.journal.first { $0.kind == "audio" }?.receipt, "rejected")
    }

    func testTemporaryAudioFailureRemainsRetryable() async throws {
        let (store, id, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appending(path: "source.wav")
        try Data(repeating: 0, count: 100).write(to: audio)
        try store.queueAudio(turnID: UUID(), practiceID: id, source: audio)
        CoachingStub.uploadStatus = 503
        let coaching = client()
        _ = await coaching.uploader.retry(practiceID: id, store: store)
        XCTAssertEqual(store.journal.first { $0.kind == "audio" }?.receipt, "pending")
        CoachingStub.uploadStatus = 201
        _ = await coaching.uploader.retry(practiceID: id, store: store)
        XCTAssertEqual(store.journal.first { $0.kind == "audio" }?.receipt, "accepted")
    }

    func testUnacknowledgedUploadsBlockFeedbackEvenWhenManifestWouldBeReady() async throws {
        let (store, id, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        CoachingStub.uploadStatus = 503
        CoachingStub.ready = true
        let note = await client().finish(practiceID: id, store: store)
        XCTAssertTrue(note.contains("pending"))
        XCTAssertFalse(CoachingStub.requests.contains { $0.path.hasSuffix("evaluation") })
        CoachingStub.uploadStatus = 201
        CoachingStub.evaluations = [(201, completed)]
        _ = await client().finish(practiceID: id, store: store)
        XCTAssertTrue(store.journal.allSatisfy { $0.receipt == "accepted" })
        let reopened = try PracticeStore(directory: root)
        XCTAssertEqual(reopened.practices.first?.reportData, completed)
    }

    func testPollingStopsAtConfiguredLimitAndKeepsProcessingState() async throws {
        let (store, id, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let running = Data("{\"status\":\"running\",\"result\":null,\"not_assessed\":[]}".utf8)
        CoachingStub.evaluations = [(202, running), (202, running), (201, completed)]
        let note = await client().evaluate(practiceID: id, store: store, explicitRetry: false)
        XCTAssertTrue(note.contains("processing"))
        XCTAssertEqual(store.practices.first?.status, "evaluating")
        XCTAssertNil(store.practices.first?.reportData)
        XCTAssertEqual(CoachingStub.requests.map(\.method), ["GET", "GET"])
        XCTAssertEqual(CoachingStub.evaluations.count, 1)
    }

    func testRetryAfterBoundsAndDefaultsWithoutRealSleeping() async throws {
        for (header, seconds) in [("0", 1), ("-5", 1), ("120", 60), ("invalid", 5), (nil, 5)] as [(String?, UInt64)] {
            let (store, id, root) = try setup()
            defer { try? FileManager.default.removeItem(at: root) }
            CoachingStub.retryAfter = header
            CoachingStub.evaluations = [(202, Data("{\"status\":\"waiting\",\"result\":null,\"not_assessed\":[]}".utf8)), (200, completed)]
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [CoachingStub.self]
            var delays: [UInt64] = []
            let client = CoachingClient(baseURL: URL(string: "https://example.com")!, session: URLSession(configuration: config), maximumPolls: 1, sleep: { delays.append($0) })
            _ = await client.evaluate(practiceID: id, store: store, explicitRetry: false)
            XCTAssertEqual(delays, [seconds * 1_000_000_000], "Header: \(header ?? "missing")")
            XCTAssertEqual(store.practices.first?.reportData, completed)
        }
    }

    func testFailedEvaluationCanBeRetriedSuccessfully() async throws {
        let (store, id, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        CoachingStub.evaluations = [(500, Data())]
        _ = await client().evaluate(practiceID: id, store: store, explicitRetry: true)
        XCTAssertEqual(store.practices.first?.status, "evaluationFailed")
        XCTAssertNil(store.practices.first?.reportData)
        CoachingStub.evaluations = [(201, completed)]
        _ = await client().evaluate(practiceID: id, store: store, explicitRetry: true)
        XCTAssertEqual(store.practices.first?.status, "feedbackReady")
        XCTAssertEqual(store.practices.first?.reportData, completed)
    }

    private func changedReport(_ change: (inout [String: Any]) -> Void) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: completed) as? [String: Any])
        var result = try XCTUnwrap(json["result"] as? [String: Any])
        change(&result)
        json["result"] = result
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testCompletedReportRejectsBlankSummary() throws {
        let data = try changedReport { $0["summary"] = " \n " }
        XCTAssertFalse(try JSONDecoder().decode(CoachingResponse.self, from: data).validCompleted)
    }

    func testCompletedReportRequiresStrengthsAndNextSteps() throws {
        for key in ["strengths", "next_steps"] {
            let data = try changedReport { $0[key] = [String]() }
            XCTAssertFalse(try JSONDecoder().decode(CoachingResponse.self, from: data).validCompleted)
        }
    }

    func testCompletedReportRejectsInvalidScoresAndBlankCategoryFeedback() throws {
        for category in ["grammar", "vocabulary", "coherence"] {
            for score in [0, 6] {
                let data = try changedReport { $0[category] = ["score": score, "feedback": "Clear"] }
                XCTAssertFalse(try JSONDecoder().decode(CoachingResponse.self, from: data).validCompleted)
            }
            let data = try changedReport { $0[category] = ["score": 4, "feedback": " \n "] }
            XCTAssertFalse(try JSONDecoder().decode(CoachingResponse.self, from: data).validCompleted)
        }
    }

    func testCompletedReportRejectsIncompleteCorrections() throws {
        for field in ["original", "improved", "explanation"] {
            let data = try changedReport {
                var correction = ["turn_id": "turn-1", "original": "I go", "improved": "I went", "explanation": "Past tense"]
                correction[field] = ""
                $0["corrections"] = [correction]
            }
            XCTAssertFalse(try JSONDecoder().decode(CoachingResponse.self, from: data).validCompleted)
        }
    }

    func testInvalidCompletedRefreshPreservesCachedReport() async throws {
        let (store, id, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveReport(completed, practiceID: id)
        CoachingStub.evaluations = [(200, try changedReport { $0["summary"] = "" })]
        _ = await client().refresh(practiceID: id, store: store)
        XCTAssertEqual(store.practices.first?.reportData, completed)
        XCTAssertEqual(store.practices.first?.status, "feedbackReady")
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
    static var retryAfter: String? = "1"
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
                                       headerFields: Self.retryAfter.map { ["Retry-After": $0] })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
