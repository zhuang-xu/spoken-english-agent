import Foundation
import MSAL
import XCTest
@testable import SpokenAgents

@MainActor final class AccountSessionTests: XCTestCase {
    private let alice = "10000000-0000-4000-8000-000000000001"
    private let bob = "20000000-0000-4000-8000-000000000002"

    private func setup() throws -> (PracticeStore, URLSession, TestBinding) {
        let root = FileManager.default.temporaryDirectory.appending(path: "accounts-\(UUID().uuidString)")
        let store = try PracticeStore(directory: root)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AccountStub.self]
        let binding = TestBinding()
        return (store, URLSession(configuration: config), binding)
    }

    private let completedReport = Data("""
    {"status":"completed","result":{"summary":"Saved feedback","grammar":{"score":4,"feedback":"Clear"},
    "vocabulary":{"score":4,"feedback":"Varied"},"coherence":{"score":4,"feedback":"Connected"},
    "strengths":["Clear"],"next_steps":["Practice"],"corrections":[]},"not_assessed":[]}
    """.utf8)

    func testRelaunchKeepsSavedLoginAfterTemporaryRefreshFailureAndRetries() async throws {
        let (store, network, binding) = try setup()
        defer { binding.delete(); AccountStub.handler = nil }
        let auth = FakeNativeAuthentication()
        AccountStub.handler = { _ in (200, Data("{\"account_id\":\"\(self.alice)\"}".utf8)) }
        let first = AccountSession(store: store, authentication: auth,
                                  baseURL: URL(string: "https://example.com")!, session: network, binding: binding)
        await first.signIn()
        auth.silentError = NSError(domain: MSALErrorDomain, code: MSALError.internal.rawValue)
        let reopened = AccountSession(store: store, authentication: auth,
                                     baseURL: URL(string: "https://example.com")!, session: network, binding: binding)
        await reopened.restore()
        XCTAssertEqual(reopened.state, .offline)
        XCTAssertEqual(reopened.accountID, alice)
        XCTAssertNotNil(binding.load())
        auth.silentError = nil
        await reopened.restore()
        XCTAssertEqual(reopened.state, .ready)
        XCTAssertEqual(auth.interactiveCalls, 1)
    }

    func testRelaunchWithUnavailableServerCanRetryWithoutSigningIn() async throws {
        let (store, network, binding) = try setup()
        defer { binding.delete(); AccountStub.handler = nil }
        let auth = FakeNativeAuthentication()
        AccountStub.handler = { _ in (200, Data("{\"account_id\":\"\(self.alice)\"}".utf8)) }
        let account = AccountSession(store: store, authentication: auth,
                                    baseURL: URL(string: "https://example.com")!, session: network, binding: binding)
        await account.signIn()
        AccountStub.handler = { _ in (503, Data()) }
        await account.restore()
        XCTAssertEqual(account.state, .offline)
        XCTAssertEqual(account.accountID, alice)
        AccountStub.handler = { _ in (200, Data("{\"account_id\":\"\(self.alice)\"}".utf8)) }
        await account.restore()
        XCTAssertEqual(account.state, .ready)
        XCTAssertEqual(auth.interactiveCalls, 1)
    }

    func testRelaunchStillRequiresSignInWhenMicrosoftRequiresInteraction() async throws {
        let (store, network, binding) = try setup()
        defer { binding.delete(); AccountStub.handler = nil }
        let auth = FakeNativeAuthentication()
        AccountStub.handler = { _ in (200, Data("{\"account_id\":\"\(self.alice)\"}".utf8)) }
        let account = AccountSession(store: store, authentication: auth,
                                    baseURL: URL(string: "https://example.com")!, session: network, binding: binding)
        await account.signIn()
        auth.silentError = NSError(domain: MSALErrorDomain, code: MSALError.interactionRequired.rawValue)
        await account.restore()
        XCTAssertEqual(account.state, .needsSignIn)
        XCTAssertFalse(account.canConnect)
    }

    func testSignOutDuringCoachingPollDoesNotSaveOldReport() async throws {
        let (store, network, binding) = try setup()
        defer { binding.delete(); AccountStub.handler = nil }
        let auth = FakeNativeAuthentication()
        var evaluations = 0
        AccountStub.handler = { request in
            if request.url?.path == "/me" { return (200, Data("{\"account_id\":\"\(self.alice)\"}".utf8)) }
            evaluations += 1
            return (202, Data("{\"status\":\"running\",\"result\":null,\"not_assessed\":[]}".utf8))
        }
        let account = AccountSession(store: store, authentication: auth, baseURL: URL(string: "https://example.com")!, session: network, binding: binding)
        await account.signIn()
        let id = UUID()
        try store.create(id: id, sessionID: UUID(), key: UUID(), preferences: SessionPreferences(speakingGoal: "Polling race", level: "B1", preferredTopic: nil, sessionDurationMinutes: 10))
        let coaching = CoachingClient(baseURL: URL(string: "https://example.com")!, session: network, account: account, maximumPolls: 1, sleep: { _ in account.signOut() })
        let note = await coaching.evaluate(practiceID: id, store: store, explicitRetry: false)
        XCTAssertTrue(note.contains("Account changed"))
        XCTAssertEqual(evaluations, 1)
        await account.signIn()
        XCTAssertNil(store.practices.first { $0.id == id }?.reportData)
    }

    func testAccountSwitchDuringRefreshPreservesPreviousAccountsReport() async throws {
        let (store, network, binding) = try setup()
        defer { binding.delete(); AccountStub.handler = nil }
        let auth = FakeNativeAuthentication()
        let started = expectation(description: "refresh started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        AccountStub.handler = { request in
            if request.url?.path == "/me" {
                let owner = request.value(forHTTPHeaderField: "Authorization") == "Bearer bob-token" ? self.bob : self.alice
                return (200, Data("{\"account_id\":\"\(owner)\"}".utf8))
            }
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return (200, self.completedReport)
        }
        let account = AccountSession(store: store, authentication: auth, baseURL: URL(string: "https://example.com")!, session: network, binding: binding)
        await account.signIn()
        let id = UUID()
        try store.create(id: id, sessionID: UUID(), key: UUID(), preferences: SessionPreferences(speakingGoal: "Refresh race", level: "B1", preferredTopic: nil, sessionDurationMinutes: 10))
        let original = Data(String(decoding: completedReport, as: UTF8.self).replacingOccurrences(of: "Saved feedback", with: "Original feedback").utf8)
        try store.saveReport(original, practiceID: id)
        let coaching = CoachingClient(baseURL: URL(string: "https://example.com")!, session: network, account: account)
        let refresh = Task { await coaching.refresh(practiceID: id, store: store) }
        await fulfillment(of: [started], timeout: 2)
        account.signOut()
        auth.interactive = NativeIdentity(accountKey: "bob-key", token: "bob-token")
        // Release the old request before verifying Bob; URLProtocol may serialize callbacks.
        release.signal()
        _ = await refresh.value
        await account.signIn()
        XCTAssertEqual(account.accountID, bob)
        XCTAssertTrue(store.practices.isEmpty)
        account.signOut()
        auth.interactive = NativeIdentity(accountKey: "alice-key", token: "alice-token")
        await account.signIn()
        XCTAssertEqual(store.practices.first { $0.id == id }?.reportData, original)
    }

    func testRejectedAPITokenIdentifiesVerificationFailureWithoutSelectingAccount() async throws {
        let (store, network, binding) = try setup()
        defer { binding.delete(); AccountStub.handler = nil }
        AccountStub.handler = { _ in (401, Data()) }
        let account = AccountSession(store: store, authentication: FakeNativeAuthentication(),
                                     baseURL: URL(string: "https://example.com")!, session: network, binding: binding)
        await account.signIn()
        XCTAssertEqual(account.state, .needsSignIn)
        XCTAssertEqual(account.signInFailure, "API account verification failed (HTTP 401).")
        XCTAssertNil(account.accountID)
        XCTAssertNil(binding.load())
        XCTAssertFalse(account.canConnect)
        account.signOut()
        XCTAssertNil(account.signInFailure)
    }

    func testTwoVerifiedAccountsSelectOnlyTheirOwnLocalHistory() async throws {
        let (store, network, binding) = try setup()
        defer { binding.delete(); AccountStub.handler = nil }
        let auth = FakeNativeAuthentication()
        auth.interactive = NativeIdentity(accountKey: "alice-key", token: "alice-token")
        let preferences = SessionPreferences(speakingGoal: "Speaking practice", level: "B1",
                                             preferredTopic: nil, sessionDurationMinutes: 10)
        let legacy = UUID()
        try store.create(id: legacy, sessionID: UUID(), key: UUID(), preferences: preferences)
        AccountStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/me")
            let id = request.value(forHTTPHeaderField: "Authorization") == "Bearer alice-token" ? self.alice : self.bob
            return (200, Data("{\"account_id\":\"\(id)\"}".utf8))
        }
        let account = AccountSession(store: store, authentication: auth,
                                     baseURL: URL(string: "https://example.com")!, session: network, binding: binding)
        XCTAssertTrue(store.practices.isEmpty)
        await account.signIn()
        XCTAssertEqual(account.accountID, alice)
        let first = UUID()
        try store.create(id: first, sessionID: UUID(), key: UUID(), preferences: preferences)
        account.signOut()
        XCTAssertTrue(store.practices.isEmpty)
        auth.interactive = NativeIdentity(accountKey: "bob-key", token: "bob-token")
        await account.signIn()
        XCTAssertEqual(account.accountID, bob)
        XCTAssertTrue(store.practices.isEmpty)
        let second = UUID()
        try store.create(id: second, sessionID: UUID(), key: UUID(), preferences: preferences)
        XCTAssertEqual(store.practices.map(\.id), [second])
        account.signOut()
        auth.interactive = NativeIdentity(accountKey: "alice-key", token: "alice-token")
        await account.signIn()
        XCTAssertEqual(store.practices.map(\.id), [first])
    }

    func testSignOutWhileTokenPendingPreventsProtectedRequest() async throws {
        let (store, network, binding) = try setup()
        defer { binding.delete(); AccountStub.handler = nil }
        let auth = FakeNativeAuthentication()
        auth.interactive = NativeIdentity(accountKey: "alice-key", token: "alice-token")
        var protectedRequests = 0
        AccountStub.handler = { request in
            if request.url?.path == "/me" { return (200, Data("{\"account_id\":\"\(self.alice)\"}".utf8)) }
            protectedRequests += 1
            return (200, Data())
        }
        let account = AccountSession(store: store, authentication: auth,
                                     baseURL: URL(string: "https://example.com")!, session: network, binding: binding)
        await account.signIn()
        auth.pauseSilent = true
        let request = URLRequest(url: URL(string: "https://example.com/sessions")!)
        let task = Task { try await account.send(request, using: network) }
        while !auth.hasPendingSilent { await Task.yield() }
        account.signOut()
        auth.resumeSilent()
        do { _ = try await task.value; XCTFail("A signed-out request must stop") }
        catch AccountFailure.changed { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(protectedRequests, 0)
        XCTAssertNil(account.accountID)
    }

    func testProtectedRequestUsesFreshTokenAndVerifiedOwner() async throws {
        let (store, network, binding) = try setup()
        defer { binding.delete(); AccountStub.handler = nil }
        let auth = FakeNativeAuthentication()
        auth.interactive = NativeIdentity(accountKey: "alice-key", token: "initial-token")
        var protectedRequests = 0
        AccountStub.handler = { request in
            if request.url?.path == "/me" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer initial-token")
                return (200, Data("{\"account_id\":\"\(self.alice)\"}".utf8))
            }
            protectedRequests += 1
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer refreshed-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Expected-Account-ID"), self.alice)
            return (200, Data())
        }
        let account = AccountSession(store: store, authentication: auth,
                                     baseURL: URL(string: "https://example.com")!, session: network, binding: binding)
        await account.signIn()
        auth.interactive = NativeIdentity(accountKey: "alice-key", token: "refreshed-token")
        let request = URLRequest(url: URL(string: "https://example.com/sessions")!)
        _ = try await account.send(request, using: network)
        XCTAssertEqual(protectedRequests, 1)
    }

    func testSignOutDuringUploadDoesNotAcceptOldReceipt() async throws {
        let (store, network, binding) = try setup()
        defer { binding.delete(); AccountStub.handler = nil }
        let auth = FakeNativeAuthentication()
        let started = expectation(description: "upload started")
        let release = DispatchSemaphore(value: 0)
        AccountStub.handler = { request in
            if request.url?.path == "/me" {
                return (200, Data("{\"account_id\":\"\(self.alice)\"}".utf8))
            }
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return (200, Data())
        }
        let account = AccountSession(store: store, authentication: auth,
                                     baseURL: URL(string: "https://example.com")!, session: network, binding: binding)
        await account.signIn()
        let id = UUID()
        try store.create(id: id, sessionID: UUID(), key: UUID(), preferences: SessionPreferences(
            speakingGoal: "Upload race", level: "B1", preferredTopic: nil, sessionDurationMinutes: 10))
        let turn = UUID()
        try store.queuePayload(id: "transcript/\(turn.uuidString)", practiceID: id,
                               kind: "learnerTranscript", bytes: Data("{\"text\":\"Hello\"}".utf8),
                               contentType: "application/json")
        let uploader = UploadJournalClient(baseURL: URL(string: "https://example.com")!,
                                           session: network, account: account)
        let upload = Task { await uploader.retry(practiceID: id, store: store) }
        await fulfillment(of: [started], timeout: 5)
        account.signOut()
        release.signal()
        let accepted = await upload.value
        XCTAssertEqual(accepted, 0)
        await account.signIn()
        XCTAssertNotEqual(store.journal.first?.receipt, "accepted")
    }

    func testOfflineRelaunchReadsOnlyPreviouslyVerifiedAccount() async throws {
        let (store, network, binding) = try setup()
        defer { binding.delete(); AccountStub.handler = nil }
        let auth = FakeNativeAuthentication()
        auth.interactive = NativeIdentity(accountKey: "alice-key", token: "alice-token")
        AccountStub.handler = { _ in (200, Data("{\"account_id\":\"\(self.alice)\"}".utf8)) }
        let first = AccountSession(store: store, authentication: auth,
                                   baseURL: URL(string: "https://example.com")!, session: network, binding: binding)
        await first.signIn()
        let id = UUID()
        try store.create(id: id, sessionID: UUID(), key: UUID(), preferences: SessionPreferences(
            speakingGoal: "Offline report", level: "B1", preferredTopic: nil, sessionDurationMinutes: 10))
        auth.silentError = URLError(.notConnectedToInternet)
        let reopened = AccountSession(store: store, authentication: auth,
                                      baseURL: URL(string: "https://example.com")!, session: network, binding: binding)
        await reopened.restore()
        XCTAssertEqual(reopened.state, .offline)
        XCTAssertEqual(store.practices.map(\.id), [id])
        XCTAssertFalse(reopened.canConnect)
        reopened.signOut()
        XCTAssertTrue(store.practices.isEmpty)
    }
}

@MainActor private final class FakeNativeAuthentication: NativeAuthentication {
    var interactiveCalls = 0
    var interactive = NativeIdentity(accountKey: "alice-key", token: "alice-token")
    var silentError: Error?
    var pauseSilent = false
    var hasPendingSilent = false
    private var cached = Set<String>()
    private var continuation: CheckedContinuation<NativeIdentity, Error>?

    func cachedAccountKeys() throws -> [String] { Array(cached) }
    func acquireInteractively() async throws -> NativeIdentity {
        interactiveCalls += 1
        cached.insert(interactive.accountKey)
        return interactive
    }
    func acquireSilently(accountKey: String) async throws -> NativeIdentity {
        if let silentError { throw silentError }
        if pauseSilent {
            hasPendingSilent = true
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        return NativeIdentity(accountKey: accountKey, token: interactive.token)
    }
    func resumeSilent() {
        continuation?.resume(returning: NativeIdentity(accountKey: "alice-key", token: "alice-token"))
        continuation = nil
    }
    func remove(accountKey: String) throws { cached.remove(accountKey) }
}

private final class AccountStub: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class TestBinding: AccountBindingStorage {
    private var value: (accountKey: String, accountID: String)?
    func load() -> (accountKey: String, accountID: String)? { value }
    func save(accountKey: String, accountID: String) throws { value = (accountKey, accountID) }
    func delete() { value = nil }
}
