import Foundation

enum BackendFailure: Error, Equatable {
    case unavailable
    case status(Int)
    case invalidResponse
}

@MainActor protocol BackendServing {
    func createSession(_ preferences: SessionPreferences, key: UUID) async throws -> SessionStart
    func heartbeat(_ id: UUID) async throws
    func endSession(_ id: UUID) async throws
}

@MainActor struct HTTPBackendClient: BackendServing {
    private let baseURL: URL
    private let session: URLSession
    private let account: AccountSession?

    init(baseURL: URL? = nil, session: URLSession = .shared, account: AccountSession? = nil) {
        let configured = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String
        self.baseURL = baseURL ?? URL(string: configured ?? "") ?? URL(string: "http://127.0.0.1:8000")!
        self.session = session
        self.account = account
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let account { return try await account.send(request, using: session) }
        return try await DiagnosticHTTP.send(request, using: session)
    }

    func createSession(_ preferences: SessionPreferences, key: UUID) async throws -> SessionStart {
        var request = URLRequest(url: baseURL.appending(path: "sessions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key.uuidString, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONEncoder().encode(preferences)
        let (data, response) = try await send(request)
        guard response.statusCode == 201 || response.statusCode == 200 else {
            throw BackendFailure.status(response.statusCode)
        }
        return try JSONDecoder().decode(SessionStart.self, from: data)
    }

    func endSession(_ id: UUID) async throws {
        var request = URLRequest(url: baseURL.appending(path: "sessions/\(id.uuidString)/end"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, response) = try await send(request)
        guard response.statusCode == 200 else { throw BackendFailure.status(response.statusCode) }
    }

    func heartbeat(_ id: UUID) async throws {
        var request = URLRequest(url: baseURL.appending(path: "sessions/\(id.uuidString)/heartbeat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw BackendFailure.unavailable
        }
    }
}
