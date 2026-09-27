import XCTest
@testable import SpokenAgents

final class SessionAPITests: XCTestCase {
    func testCreateSessionSendsKeyAndDecodesCredential() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let key = UUID()
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/sessions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), key.uuidString)
            let body: Data
            if let direct = request.httpBody {
                body = direct
            } else {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                var collected = Data()
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    collected.append(contentsOf: bytes.prefix(count))
                }
                body = collected
            }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["speaking_goal"] as? String, "Interview practice")
            XCTAssertEqual(json["session_duration_minutes"] as? Int, 10)
            return (201, Data("""
            {"session":{"id":"10000000-0000-4000-8000-000000000001","status":"active"},
             "realtime":{"webrtc_url":"https://example.com/openai/v1/realtime/calls",
             "client_credential":{"value":"short-lived","expires_at":"2099-01-01T00:00:00Z"}}}
            """.utf8))
        }
        defer { StubURLProtocol.handler = nil }
        let client = HTTPBackendClient(baseURL: URL(string: "http://127.0.0.1:8000")!, session: session)
        let result = try await client.createSession(SessionPreferences(
            speakingGoal: "Interview practice", level: "B1", preferredTopic: nil,
            sessionDurationMinutes: 10), key: key)
        XCTAssertEqual(result.session.status, "active")
        XCTAssertTrue(result.realtime?.clientCredential.isValid == true)
    }

    func testRealtimeEventReadsManualTurnConfirmation() throws {
        let data = Data("""
        {"type":"session.updated","session":{"audio":{"input":{"turn_detection":null}}}}
        """.utf8)
        XCTAssertEqual(RealtimeEvent(data: data)?.turnDetectionDisabled, true)
    }

    func testSDPExchangeUsesReturnedHTTPSURLAndTemporaryCredential() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/openai/v1/realtime/calls")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer temporary-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/sdp")
            let body: Data
            if let direct = request.httpBody {
                body = direct
            } else {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 1024)
                let count = stream.read(&bytes, maxLength: bytes.count)
                body = Data(bytes.prefix(max(count, 0)))
            }
            XCTAssertEqual(body, Data("v=0\r\noffer".utf8))
            return (201, Data("v=0\r\nanswer".utf8))
        }
        defer { StubURLProtocol.handler = nil }
        let exchange = HTTPSDPExchanger(session: URLSession(configuration: configuration))
        let answer = try await exchange.exchange(offer: "v=0\r\noffer",
            url: URL(string: "https://example.com/openai/v1/realtime/calls")!, credential: "temporary-token")
        XCTAssertEqual(answer, "v=0\r\nanswer")
    }

    func testSDPExchangeRejectsUnsafeURLBeforeSendingCredential() async {
        let exchange = HTTPSDPExchanger()
        do {
            _ = try await exchange.exchange(offer: "v=0", url: URL(string: "http://example.com/openai/v1/realtime/calls")!, credential: "temporary-token")
            XCTFail("Expected invalid URL")
        } catch RealtimeFailure.invalidURL {
            // Expected: no request was made.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler?(request) ?? (500, Data())
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
