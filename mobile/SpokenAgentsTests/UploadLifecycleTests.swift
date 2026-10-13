import Foundation
import Synchronization
import XCTest
@testable import SpokenAgents

@MainActor final class UploadLifecycleTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let store: PracticeStore
        let practice: UUID
        let network: URLSession
        let client: UploadJournalClient
        let host: String
        let gate: UploadResponseGate
        func close() {
            network.invalidateAndCancel()
            GatedUploadProtocol.unregister(host)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func fixture(hold: Bool = true, error: URLError? = nil) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "upload-lifecycle-\(UUID().uuidString)")
        let store = try PracticeStore(directory: root, accountID: "alice")
        let practice = UUID()
        try store.create(id: practice, sessionID: UUID(), key: UUID(), preferences: SessionPreferences(
            speakingGoal: "Lifecycle test", level: "B1", preferredTopic: nil, sessionDurationMinutes: 10))
        try store.queuePayload(id: "transcript/\(UUID().uuidString)", practiceID: practice, kind: "learnerTranscript",
                               bytes: Data("immutable turn bytes".utf8), contentType: "application/json")
        let gate = UploadResponseGate(started: expectation(description: "upload reached network"), hold: hold, error: error)
        let host = "gate-\(UUID().uuidString.lowercased()).invalid"
        GatedUploadProtocol.register(host, gate: gate)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatedUploadProtocol.self]
        let network = URLSession(configuration: configuration)
        return Fixture(root: root, store: store, practice: practice, network: network,
                       client: UploadJournalClient(baseURL: URL(string: "https://\(host)")!, session: network),
                       host: host, gate: gate)
    }

    func testLateAcknowledgmentAfterAccountSwitchBackCannotAcceptOldGeneration() async throws {
        let f = try fixture()
        defer { f.close() }
        let upload = Task { await f.client.retry(practiceID: f.practice, store: f.store) }
        await fulfillment(of: [f.gate.started], timeout: 2)
        f.store.switchAccount(to: "bob")
        f.store.switchAccount(to: "alice")
        f.gate.release.signal()
        let accepted = await upload.value
        XCTAssertEqual(accepted, 0)
        XCTAssertEqual(f.store.journal.first?.receipt, "pending")
        XCTAssertNil(f.store.journal.first?.issue)
        XCTAssertEqual(f.gate.bodies.count, 1)
    }

    func testLateAcknowledgmentAfterPracticeDeletionCannotResurrectMetadata() async throws {
        let f = try fixture()
        defer { f.close() }
        let upload = Task { await f.client.retry(practiceID: f.practice, store: f.store) }
        await fulfillment(of: [f.gate.started], timeout: 2)
        try f.store.delete(f.practice)
        f.gate.release.signal()
        let accepted = await upload.value
        XCTAssertEqual(accepted, 0)
        XCTAssertTrue(f.store.practices.isEmpty)
        XCTAssertTrue(f.store.journal.isEmpty)
    }

    func testCancelledNetworkUploadRetainsPendingBytesAndReleasesRetryLock() async throws {
        let f = try fixture()
        defer { f.close() }
        let expected = try f.store.bytes(for: XCTUnwrap(f.store.journal.first))
        let upload = Task { await f.client.retry(practiceID: f.practice, store: f.store) }
        await fulfillment(of: [f.gate.started], timeout: 2)
        upload.cancel()
        f.gate.release.signal()
        let cancelled = await upload.value
        XCTAssertEqual(cancelled, 0)
        XCTAssertEqual(f.store.journal.first?.receipt, "pending")
        XCTAssertNil(f.store.journal.first?.issue)
        f.gate.configure(hold: false, error: nil)
        let retried = await f.client.retry(practiceID: f.practice, store: f.store)
        XCTAssertEqual(retried, 1)
        XCTAssertEqual(f.gate.bodies, [expected, expected])
    }

    func testNetworkTimeoutKeepsExactBytesAndNextRetryCanSucceed() async throws {
        let f = try fixture(hold: false, error: URLError(.timedOut))
        defer { f.close() }
        let expected = try f.store.bytes(for: XCTUnwrap(f.store.journal.first))
        let failed = await f.client.retry(practiceID: f.practice, store: f.store)
        await fulfillment(of: [f.gate.started], timeout: 2)
        XCTAssertEqual(failed, 0)
        XCTAssertEqual(f.store.journal.first?.receipt, "pending")
        XCTAssertNotNil(f.store.journal.first?.issue)
        f.gate.configure(hold: false, error: nil)
        let retried = await f.client.retry(practiceID: f.practice, store: f.store)
        XCTAssertEqual(retried, 1)
        XCTAssertEqual(f.gate.bodies, [expected, expected])
        XCTAssertNil(f.store.journal.first?.issue)
    }
}

private final class UploadResponseGate: @unchecked Sendable {
    let started: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var holding: Bool
    private var responseError: URLError?
    private var capturedBodies: [Data] = []
    var bodies: [Data] { lock.withLock { capturedBodies } }

    init(started: XCTestExpectation, hold: Bool, error: URLError?) {
        self.started = started; holding = hold; responseError = error
    }
    func configure(hold: Bool, error: URLError?) {
        lock.withLock { holding = hold; responseError = error }
    }
    func capture(_ bytes: Data) -> (Bool, URLError?) {
        let snapshot = lock.withLock { () -> (Bool, URLError?, Bool) in
            capturedBodies.append(bytes)
            return (holding, responseError, capturedBodies.count == 1)
        }
        if snapshot.2 { started.fulfill() }
        return (snapshot.0, snapshot.1)
    }
}

private final class GatedUploadProtocol: URLProtocol {
    private static let registryLock = NSLock()
    private static var gates: [String: UploadResponseGate] = [:]
    private let stopped = Atomic<Bool>(false)
    static func register(_ host: String, gate: UploadResponseGate) {
        registryLock.withLock { gates[host] = gate }
    }
    static func unregister(_ host: String) {
        _ = registryLock.withLock { gates.removeValue(forKey: host) }
    }
    private static func gate(for request: URLRequest) -> UploadResponseGate? {
        registryLock.withLock { request.url?.host.flatMap { gates[$0] } }
    }
    override class func canInit(with request: URLRequest) -> Bool { gate(for: request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let gate = Self.gate(for: request) else { return }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let (hold, error) = gate.capture(body)
        if hold, gate.release.wait(timeout: .now() + 5) == .timedOut {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        guard !stopped.load(ordering: .acquiring) else { return }
        if let error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        stopped.store(true, ordering: .releasing)
        Self.gate(for: request)?.release.signal()
    }
}
