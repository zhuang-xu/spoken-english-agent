import Foundation

#if DEBUG
// Only explicit UI-test launches use these dependencies; release builds omit them.
@MainActor final class UITestEnvironment {
    static let alice = "10000000-0000-4000-8000-000000000001"
    static let bob = "20000000-0000-4000-8000-000000000002"
    let store: PracticeStore
    let account: AccountSession
    let call: CallCoordinator
    let coaching: CoachingClient

    static func makeIfRequested() -> UITestEnvironment? {
        let environment = ProcessInfo.processInfo.environment
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              let rawID = environment["UI_TEST_ID"], let id = UUID(uuidString: rawID) else { return nil }
        do { return try UITestEnvironment(id: id, scenario: environment["UI_TEST_SCENARIO"] ?? "ready") }
        catch { fatalError("Could not initialize isolated UI test storage: \(error)") }
    }

    private init(id: UUID, scenario: String) throws {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "UITests/\(id.uuidString)")
        store = try PracticeStore(directory: root, accountID: Self.alice)
        let marker = root.appending(path: "seeded")
        if !FileManager.default.fileExists(atPath: marker.path) {
            if ["history", "offline", "refreshFailure", "accountSwitch"].contains(scenario) {
                try Self.seed(store, goal: "Airport practice", completed: true)
            } else if ["incomplete", "processing", "evaluationFailed"].contains(scenario) {
                let practice = try Self.seed(store, goal: "Pending practice", completed: false)
                try store.setStatus(scenario == "processing" ? "evaluating" : scenario == "evaluationFailed" ? "evaluationFailed" : "incomplete", for: practice)
            }
            store.switchAccount(to: Self.bob)
            try Self.seed(store, goal: "Bob private practice", completed: true)
            store.switchAccount(to: Self.alice)
            try Data().write(to: marker)
        }
        UITestHTTP.scenario = scenario
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UITestHTTP.self]
        let network = URLSession(configuration: configuration)
        let url = URL(string: "https://ui.test")!
        let binding = UITestBinding(signedIn: !["signedOut", "signInFailure"].contains(scenario))
        account = AccountSession(store: store, authentication: UITestAuthentication(scenario: scenario),
                                 baseURL: url, session: network, binding: binding)
        coaching = CoachingClient(baseURL: url, session: network, account: account, maximumPolls: 1, sleep: { _ in })
        call = CallCoordinator(backend: HTTPBackendClient(baseURL: url, session: network, account: account),
                               permission: UITestPermission(allowed: scenario != "permissionDenied"),
                               transport: UITestTransport(failFirst: scenario == "connectionRetry"),
                               recorder: UITestRecorder(root: root), store: store, coaching: coaching)
    }

    @discardableResult private static func seed(_ store: PracticeStore, goal: String, completed: Bool) throws -> UUID {
        let id = UUID()
        try store.create(id: id, sessionID: UUID(), key: UUID(), preferences: SessionPreferences(
            speakingGoal: goal, level: "B1", preferredTopic: "Travel", sessionDurationMinutes: 10))
        try store.savePart(id: "seed/0", practiceID: id, speaker: "Agent", text: "Welcome to your saved conversation.", offsetMilliseconds: 0)
        if completed { try store.saveReport(UITestHTTP.report, practiceID: id) }
        else {
            try store.queuePayload(id: "agent/seed/0", practiceID: id, kind: "agentTranscript",
                                   bytes: Data("{\"text\":\"Welcome\"}".utf8), contentType: "application/json")
        }
        return id
    }
}

private final class UITestBinding: AccountBindingStorage {
    private var value: (accountKey: String, accountID: String)?
    init(signedIn: Bool) {
        value = signedIn ? ("alice", "10000000-0000-4000-8000-000000000001") : nil
    }
    func load() -> (accountKey: String, accountID: String)? { value }
    func save(accountKey: String, accountID: String) throws { value = (accountKey, accountID) }
    func delete() { value = nil }
}

@MainActor private final class UITestAuthentication: NativeAuthentication {
    let scenario: String
    private var nextAccount = "alice"
    init(scenario: String) { self.scenario = scenario }
    func cachedAccountKeys() throws -> [String] { ["alice", "bob"] }
    func acquireSilently(accountKey: String) async throws -> NativeIdentity {
        if scenario == "offline" { throw URLError(.notConnectedToInternet) }
        return NativeIdentity(accountKey: accountKey, token: accountKey)
    }
    func acquireInteractively() async throws -> NativeIdentity { NativeIdentity(accountKey: nextAccount, token: nextAccount) }
    func remove(accountKey: String) throws { if scenario == "accountSwitch" { nextAccount = "bob" } }
}

private final class UITestHTTP: URLProtocol {
    static var scenario = "ready"
    static let report = Data("""
    {"status":"completed","result":{"summary":"You communicated clearly.","grammar":{"score":4,"feedback":"Clear grammar"},
    "vocabulary":{"score":3,"feedback":"Try varied words"},"coherence":{"score":4,"feedback":"Connected ideas"},
    "strengths":["Clear answers"],"next_steps":["Practice longer turns"],
    "corrections":[{"turn_id":"turn-1","original":"I go yesterday","improved":"I went yesterday","explanation":"Use past tense"}]},
    "not_assessed":["pronunciation","spoken_fluency"]}
    """.utf8)
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "ui.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        var status = 200
        var body = Data()
        if path == "/me" {
            if Self.scenario == "signInFailure" { status = 401 }
            else {
                let owner = request.value(forHTTPHeaderField: "Authorization") == "Bearer bob"
                    ? "20000000-0000-4000-8000-000000000002" : "10000000-0000-4000-8000-000000000001"
                body = Data("{\"account_id\":\"\(owner)\"}".utf8)
            }
        } else if path == "/sessions" {
            status = 201
            body = Data("""
            {"session":{"id":"30000000-0000-4000-8000-000000000003","status":"active"},
            "realtime":{"webrtc_url":"https://ui.test/realtime","client_credential":{"value":"fixture","expires_at":"2099-01-01T00:00:00Z"}}}
            """.utf8)
        } else if path.hasSuffix("/audio") && Self.scenario == "rejectedAudio" {
            status = 422
        } else if path.hasSuffix("upload-manifest") {
            body = Data("""
            {"ready_for_evaluation":true,"missing":{"audio_turn_ids":[],"transcript_turn_ids":[],"agent_transcripts":[]},
            "unexpected":{"audio_turn_ids":[],"transcript_turn_ids":[],"agent_transcripts":[]}}
            """.utf8)
        } else if path.hasSuffix("evaluation") {
            if Self.scenario == "refreshFailure" { status = 503 }
            else if Self.scenario == "processing" {
                status = 202
                body = Data("{\"status\":\"running\",\"result\":null,\"not_assessed\":[]}".utf8)
            } else { body = Self.report }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct UITestPermission: MicrophonePermissionProviding {
    let allowed: Bool
    func request() async -> Bool { allowed }
}

private final class UITestTransport: RealtimeTransporting {
    var onEvent: ((RealtimeEvent) -> Void)?
    private var failFirst: Bool
    private var turn = 0
    init(failFirst: Bool) { self.failFirst = failFirst }
    func connect(url: URL, credential: String) async throws {
        if failFirst { failFirst = false; throw RealtimeFailure.connectionTimedOut }
    }
    func send(_ payload: [String: Any]) throws {
        switch payload["type"] as? String {
        case "session.update": emit(RealtimeEvent(type: "session.updated", turnDetectionDisabled: true))
        case "input_audio_buffer.clear": emit(RealtimeEvent(type: "input_audio_buffer.cleared"))
        case "input_audio_buffer.commit":
            turn += 1
            let item = "learner-\(turn)"
            emit(RealtimeEvent(type: "input_audio_buffer.committed", itemID: item))
            emit(RealtimeEvent(type: "conversation.item.input_audio_transcription.completed", itemID: item, transcript: "I would like a ticket."))
            emit(RealtimeEvent(type: "response.output_audio_transcript.done", itemID: "agent-\(turn)", transcript: "Where would you like to go?", contentIndex: 0, responseID: "response-\(turn)"))
        default: break
        }
    }
    private func emit(_ event: RealtimeEvent) { onEvent?(event) }
    func setInputEnabled(_ enabled: Bool) {}
    func startInput() throws {}
    func setSpeakerEnabled(_ enabled: Bool) throws {}
    func close() { onEvent = nil }
}

private final class UITestRecorder: TurnRecording {
    let root: URL
    init(root: URL) { self.root = root }
    func start(turnID: UUID) throws {}
    func stop() throws -> URL {
        let url = root.appending(path: "turn.wav")
        try Data(repeating: 1, count: 100).write(to: url)
        return url
    }
    func cancel() {}
}
#endif
