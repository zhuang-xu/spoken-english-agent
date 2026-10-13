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

    func testDeleteRemovesOnlySelectedPracticeAndItsFiles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PracticeStore(directory: root)
        let deleted = UUID(), kept = UUID()
        var paths: [UUID: URL] = [:]
        for id in [deleted, kept] {
            try store.create(id: id, sessionID: UUID(), key: UUID(), preferences: preferences)
            try store.savePart(id: "agent-\(id)/0", practiceID: id, speaker: "Agent", text: "Hello", offsetMilliseconds: 0)
            try store.saveReport(report, practiceID: id)
            let source = root.appending(path: "\(id).wav")
            try Data(repeating: 7, count: 100).write(to: source)
            try store.queueAudio(turnID: UUID(), practiceID: id, source: source)
            let item = try XCTUnwrap(store.journal.first { $0.practiceID == id })
            paths[id] = root.appending(path: "Audio/\(try XCTUnwrap(item.fileName))")
        }
        try store.delete(deleted)
        let reopened = try PracticeStore(directory: root)
        XCTAssertEqual(reopened.practices.map(\.id), [kept])
        XCTAssertTrue(reopened.parts.allSatisfy { $0.practiceID == kept })
        XCTAssertEqual(reopened.parts.count, 1)
        XCTAssertEqual(reopened.journal.count, 1)
        XCTAssertEqual(reopened.journal.first?.practiceID, kept)
        XCTAssertEqual(reopened.practices.first?.reportData, report)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(paths[deleted]).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(paths[kept]).path))
    }

    func testPartialUploadSuccessRetriesOnlyPendingItems() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root); UploadStub.statuses = []; UploadStub.requestPaths = [] }
        let store = try PracticeStore(directory: root), id = UUID()
        try store.create(id: id, sessionID: UUID(), key: UUID(), preferences: preferences)
        for _ in 0..<2 {
            try store.queuePayload(id: "transcript/\(UUID())", practiceID: id, kind: "learnerTranscript", bytes: Data("saved".utf8), contentType: "application/json")
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadStub.self]
        let client = UploadJournalClient(baseURL: URL(string: "https://example.com")!, session: URLSession(configuration: config))
        UploadStub.requestPaths = []
        UploadStub.statuses = [200, 503]
        let first = await client.retry(practiceID: id, store: store)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(store.journal.filter { $0.receipt == "accepted" }.count, 1)
        let pending = try XCTUnwrap(store.journal.first { $0.receipt != "accepted" })
        XCTAssertEqual(try store.bytes(for: pending), Data("saved".utf8))
        UploadStub.statuses = [201]
        let second = await client.retry(practiceID: id, store: store)
        XCTAssertEqual(second, 1)
        XCTAssertEqual(UploadStub.requestPaths.count, 3)
        XCTAssertEqual(UploadStub.requestPaths[1], UploadStub.requestPaths[2])
        let third = await client.retry(practiceID: id, store: store)
        XCTAssertEqual(third, 0)
        XCTAssertEqual(UploadStub.requestPaths.count, 3)
    }

    func testUploadNetworkFailurePreservesPendingBytes() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root); UploadStub.error = nil }
        let store = try PracticeStore(directory: root), id = UUID()
        try store.create(id: id, sessionID: UUID(), key: UUID(), preferences: preferences)
        let payload = Data("pending bytes".utf8)
        try store.queuePayload(id: "transcript/\(UUID())", practiceID: id, kind: "learnerTranscript", bytes: payload, contentType: "application/json")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadStub.self]
        UploadStub.error = URLError(.notConnectedToInternet)
        let accepted = await UploadJournalClient(baseURL: URL(string: "https://example.com")!, session: URLSession(configuration: config)).retry(practiceID: id, store: store)
        XCTAssertEqual(accepted, 0)
        let reopened = try PracticeStore(directory: root)
        let item = try XCTUnwrap(reopened.journal.first)
        XCTAssertEqual(item.receipt, "pending")
        XCTAssertEqual(try reopened.bytes(for: item), payload)
        XCTAssertEqual(reopened.practices.first?.status, "incomplete")
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

    func testCompletedReportRemovesAcceptedAudioButKeepsPendingRetries() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PracticeStore(directory: root)
        let practice = UUID(), accepted = UUID(), pending = UUID()
        try store.create(id: practice, sessionID: UUID(), key: UUID(), preferences: preferences)
        for turn in [accepted, pending] {
            let source = root.appending(path: "\(turn.uuidString).wav")
            try Data(repeating: 7, count: 100).write(to: source)
            try store.queueAudio(turnID: turn, practiceID: practice, source: source)
        }
        try store.markAccepted("audio/\(accepted.uuidString)", practiceID: practice)
        let pendingItem = try XCTUnwrap(store.journal.first { $0.id == "audio/\(pending.uuidString)" })
        try store.saveReport(report, practiceID: practice)
        let acceptedItem = try XCTUnwrap(store.journal.first { $0.id == "audio/\(accepted.uuidString)" })
        XCTAssertNil(acceptedItem.fileName)
        XCTAssertEqual(try store.bytes(for: pendingItem).count, 100)
        XCTAssertEqual(store.practices.first?.status, "feedbackReady")
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

    func testAsyncRecordedAudioSaveIsIdempotentAndUploadBytesAreVerified() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PracticeStore(directory: root)
        let practice = UUID(), turn = UUID()
        try store.create(id: practice, sessionID: UUID(), key: UUID(), preferences: preferences)
        let bytes = Data(repeating: 7, count: 100)
        for index in 0..<2 {
            let source = root.appending(path: "source-\(index).wav")
            try bytes.write(to: source)
            try await store.queueRecordedAudio(turnID: turn, practiceID: practice, source: source)
        }
        XCTAssertEqual(store.journal.count, 1)
        let item = try XCTUnwrap(store.journal.first)
        let uploaded = try await store.uploadBytes(for: item)
        XCTAssertEqual(uploaded, bytes)
        let saved = root.appending(path: "Audio/\(try XCTUnwrap(item.fileName))")
        try Data(repeating: 8, count: 100).write(to: saved)
        do {
            _ = try await store.uploadBytes(for: item)
            XCTFail("Corrupt audio must not be uploaded")
        } catch { XCTAssertEqual(String(describing: error), "corruptPayload") }
    }
    func testConcurrentAsyncSavesKeepOneJournalEntryAndOneOwnedFile() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PracticeStore(directory: root)
        let practice = UUID(), turn = UUID()
        try store.create(id: practice, sessionID: UUID(), key: UUID(), preferences: preferences)
        let first = root.appending(path: "first.wav"), second = root.appending(path: "second.wav")
        let bytes = Data(repeating: 4, count: 100)
        try bytes.write(to: first); try bytes.write(to: second)
        async let a: Void = store.queueRecordedAudio(turnID: turn, practiceID: practice, source: first)
        async let b: Void = store.queueRecordedAudio(turnID: turn, practiceID: practice, source: second)
        _ = try await (a, b)
        XCTAssertEqual(store.journal.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Audio").path).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testAccountSwitchAwayAndBackDuringFilePreparationCannotCommitOldWork() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchQueue(label: "account-file-barrier")
        let store = try PracticeStore(directory: root, accountID: "alice", fileQueue: queue)
        let practice = UUID(), turn = UUID()
        try store.create(id: practice, sessionID: UUID(), key: UUID(), preferences: preferences)
        let source = root.appending(path: "source.wav")
        try Data(repeating: 3, count: 100).write(to: source)
        queue.suspend()
        let entered = expectation(description: "save entered")
        let saving = Task { @MainActor in
            entered.fulfill()
            try await store.queueRecordedAudio(turnID: turn, practiceID: practice, source: source)
        }
        await fulfillment(of: [entered], timeout: 1)
        store.switchAccount(to: "bob")
        store.switchAccount(to: "alice")
        queue.resume()
        do { try await saving.value; XCTFail("Old account generation must be rejected") }
        catch { XCTAssertEqual(String(describing: error), "missingPayload") }
        XCTAssertTrue(store.journal.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Audio").path).isEmpty)
    }

    func testCancelledFilePreparationDoesNotCommitOrUploadAndCanRetry() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchQueue(label: "cancel-file-barrier")
        let store = try PracticeStore(directory: root, fileQueue: queue)
        let practice = UUID(), turn = UUID()
        try store.create(id: practice, sessionID: UUID(), key: UUID(), preferences: preferences)
        let source = root.appending(path: "source.wav")
        try Data(repeating: 3, count: 100).write(to: source)
        queue.suspend()
        let entered = expectation(description: "save entered")
        let saving = Task { @MainActor in
            entered.fulfill()
            try await store.queueRecordedAudio(turnID: turn, practiceID: practice, source: source)
        }
        await fulfillment(of: [entered], timeout: 1)
        saving.cancel()
        queue.resume()
        do { try await saving.value; XCTFail("Cancelled save must not commit") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(store.journal.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Audio").path).isEmpty)
        try await store.queueRecordedAudio(turnID: turn, practiceID: practice, source: source)
        XCTAssertEqual(store.journal.count, 1)
    }

    func testConcurrentRetryAndCancellationDuringPreparationSendNoRequest() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root); UploadStub.requestPaths = [] }
        let queue = DispatchQueue(label: "upload-file-barrier")
        let store = try PracticeStore(directory: root, fileQueue: queue)
        let practice = UUID(), turn = UUID()
        try store.create(id: practice, sessionID: UUID(), key: UUID(), preferences: preferences)
        try store.queuePayload(id: "transcript/\(turn.uuidString)", practiceID: practice, kind: "learnerTranscript",
                               bytes: Data("saved".utf8), contentType: "application/json")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadStub.self]
        let network = URLSession(configuration: config)
        defer { network.invalidateAndCancel() }
        let client = UploadJournalClient(baseURL: URL(string: "https://example.com")!, session: network)
        UploadStub.requestPaths = []
        queue.suspend()
        let entered = expectation(description: "retry entered")
        let first = Task { @MainActor in entered.fulfill(); return await client.retry(practiceID: practice, store: store) }
        await fulfillment(of: [entered], timeout: 1)
        let duplicate = await client.retry(practiceID: practice, store: store)
        XCTAssertEqual(duplicate, 0)
        first.cancel()
        queue.resume()
        let cancelled = await first.value
        XCTAssertEqual(cancelled, 0)
        XCTAssertTrue(UploadStub.requestPaths.isEmpty)
        XCTAssertEqual(store.journal.first?.receipt, "pending")
        XCTAssertNil(store.journal.first?.issue)
        UploadStub.status = 200
        let retried = await client.retry(practiceID: practice, store: store)
        XCTAssertEqual(retried, 1)
        XCTAssertEqual(UploadStub.requestPaths.count, 1)
    }

    func testDeletedPracticeDuringUploadPreparationSendsNoRequest() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root); UploadStub.requestPaths = [] }
        let queue = DispatchQueue(label: "deleted-upload-barrier")
        let store = try PracticeStore(directory: root, fileQueue: queue)
        let practice = UUID()
        try store.create(id: practice, sessionID: UUID(), key: UUID(), preferences: preferences)
        try store.queuePayload(id: "transcript/\(UUID().uuidString)", practiceID: practice, kind: "learnerTranscript",
                               bytes: Data("saved".utf8), contentType: "application/json")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadStub.self]
        let network = URLSession(configuration: config)
        defer { network.invalidateAndCancel() }
        let client = UploadJournalClient(baseURL: URL(string: "https://example.com")!, session: network)
        UploadStub.requestPaths = []
        queue.suspend()
        let entered = expectation(description: "retry entered")
        let upload = Task { @MainActor in entered.fulfill(); return await client.retry(practiceID: practice, store: store) }
        await fulfillment(of: [entered], timeout: 1)
        try store.delete(practice)
        queue.resume()
        let accepted = await upload.value
        XCTAssertEqual(accepted, 0)
        XCTAssertTrue(UploadStub.requestPaths.isEmpty)
        XCTAssertTrue(store.journal.isEmpty)
    }

    func testAccountSwitchDuringUploadPreparationSendsNoRequest() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root); UploadStub.requestPaths = [] }
        let queue = DispatchQueue(label: "account-upload-barrier")
        let store = try PracticeStore(directory: root, accountID: "alice", fileQueue: queue)
        let practice = UUID()
        try store.create(id: practice, sessionID: UUID(), key: UUID(), preferences: preferences)
        try store.queuePayload(id: "transcript/\(UUID().uuidString)", practiceID: practice, kind: "learnerTranscript",
                               bytes: Data("saved".utf8), contentType: "application/json")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadStub.self]
        let network = URLSession(configuration: config)
        defer { network.invalidateAndCancel() }
        let client = UploadJournalClient(baseURL: URL(string: "https://example.com")!, session: network)
        UploadStub.requestPaths = []
        queue.suspend()
        let entered = expectation(description: "retry entered")
        let upload = Task { @MainActor in entered.fulfill(); return await client.retry(practiceID: practice, store: store) }
        await fulfillment(of: [entered], timeout: 1)
        store.switchAccount(to: "bob"); store.switchAccount(to: "alice")
        queue.resume()
        let accepted = await upload.value
        XCTAssertEqual(accepted, 0)
        XCTAssertTrue(UploadStub.requestPaths.isEmpty)
        XCTAssertEqual(store.journal.first?.receipt, "pending")
    }

    func testInterruptedAsyncSaveFilenameRecoversAudioUnderOriginalTurn() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: PracticeStore? = try PracticeStore(directory: root)
        let practice = UUID(), turn = UUID()
        try store!.create(id: practice, sessionID: UUID(), key: UUID(), preferences: preferences)
        let bytes = Data(repeating: 9, count: 100)
        let name = "\(practice.uuidString)-\(turn.uuidString)-\(UUID().uuidString).wav"
        try bytes.write(to: root.appending(path: "Audio/\(name)"))
        store = nil
        let reopened = try PracticeStore(directory: root)
        let item = try XCTUnwrap(reopened.journal.first)
        XCTAssertEqual(item.id, "audio/\(turn.uuidString)")
        XCTAssertEqual(item.fileName, name)
        XCTAssertEqual(try reopened.bytes(for: item), bytes)
        XCTAssertEqual(reopened.practices.first?.status, "incomplete")
        reopened.reconcile()
        XCTAssertEqual(reopened.journal.count, 1)
    }

    private enum SaveInterruption { case cancellation, accountChange, deletion }

    private func interruptAfterFileWrite(_ interruption: SaveInterruption) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let written = expectation(description: "durable file written before metadata commit")
        let release = DispatchSemaphore(value: 0)
        let store = try PracticeStore(directory: root, accountID: "alice", afterAudioFileWrite: { target in
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
            written.fulfill()
            _ = release.wait(timeout: .now() + 5)
        })
        let practice = UUID()
        try store.create(id: practice, sessionID: UUID(), key: UUID(), preferences: preferences)
        let source = root.appending(path: "source.wav")
        try Data(repeating: 7, count: 100).write(to: source)
        let saving = Task { try await store.queueRecordedAudio(turnID: UUID(), practiceID: practice, source: source) }
        await fulfillment(of: [written], timeout: 2)
        switch interruption {
        case .cancellation: saving.cancel()
        case .accountChange: store.switchAccount(to: "bob"); store.switchAccount(to: "alice")
        case .deletion: try store.delete(practice)
        }
        release.signal()
        do { try await saving.value; XCTFail("Interrupted write must not commit") }
        catch {
            if interruption == .cancellation { XCTAssertTrue(error is CancellationError) }
            else { XCTAssertEqual(String(describing: error), "missingPayload") }
        }
        XCTAssertTrue(store.journal.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Audio").path).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Caller retains the source after failed commit")
    }

    func testCancellationAfterFileWriteDeletesUncommittedTarget() async throws {
        try await interruptAfterFileWrite(.cancellation)
    }

    func testAccountChangeAfterFileWriteDeletesUncommittedTarget() async throws {
        try await interruptAfterFileWrite(.accountChange)
    }

    func testPracticeDeletionAfterFileWriteDeletesUncommittedTarget() async throws {
        try await interruptAfterFileWrite(.deletion)
    }

    func testConcurrentConflictingSavesPreserveWinnerAndRemoveLosingTarget() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PracticeStore(directory: root)
        let practice = UUID(), turn = UUID()
        try store.create(id: practice, sessionID: UUID(), key: UUID(), preferences: preferences)
        let sources = [root.appending(path: "one.wav"), root.appending(path: "two.wav")]
        let values = [Data(repeating: 1, count: 100), Data(repeating: 2, count: 100)]
        for index in 0..<2 { try values[index].write(to: sources[index]) }
        let a = Task { () -> Result<Void, Error> in
            do { try await store.queueRecordedAudio(turnID: turn, practiceID: practice, source: sources[0]); return .success(()) }
            catch { return .failure(error) }
        }
        let b = Task { () -> Result<Void, Error> in
            do { try await store.queueRecordedAudio(turnID: turn, practiceID: practice, source: sources[1]); return .success(()) }
            catch { return .failure(error) }
        }
        let results = [await a.value, await b.value]
        var successes = 0
        for result in results {
            switch result {
            case .success: successes += 1
            case .failure(let error): XCTAssertEqual(String(describing: error), "conflictingContent")
            }
        }
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(store.journal.count, 1)
        let winner = try store.bytes(for: XCTUnwrap(store.journal.first))
        XCTAssertTrue(values.contains(winner))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Audio").path).count, 1)
        XCTAssertEqual(sources.filter { FileManager.default.fileExists(atPath: $0.path) }.count, 1)
    }

    func testDurableWriteFailureKeepsSourceAndAllowsRetryAfterRepair() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PracticeStore(directory: root)
        let practice = UUID(), turn = UUID()
        try store.create(id: practice, sessionID: UUID(), key: UUID(), preferences: preferences)
        let source = root.appending(path: "source.wav")
        try Data(repeating: 3, count: 100).write(to: source)
        let audioDirectory = root.appending(path: "Audio")
        try FileManager.default.removeItem(at: audioDirectory)
        try Data("blocked".utf8).write(to: audioDirectory)
        do { try await store.queueRecordedAudio(turnID: turn, practiceID: practice, source: source); XCTFail("Write must fail") }
        catch { XCTAssertNotNil(error as NSError) }
        XCTAssertTrue(store.journal.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        try FileManager.default.removeItem(at: audioDirectory)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try await store.queueRecordedAudio(turnID: turn, practiceID: practice, source: source)
        XCTAssertEqual(store.journal.count, 1)
    }

}

private final class UploadStub: URLProtocol {
    static var status = 200
    static var statuses: [Int] = []
    static var requestPaths: [String] = []
    static var error: Error?
    static var body: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestPaths.append(request.url!.path)
        if let error = Self.error { client?.urlProtocol(self, didFailWithError: error); return }
        let status = Self.statuses.isEmpty ? Self.status : Self.statuses.removeFirst()
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
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
