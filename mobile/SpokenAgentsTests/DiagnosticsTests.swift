import Foundation
import XCTest
@testable import SpokenAgents

final class DiagnosticsTests: XCTestCase {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID().uuidString)")
    }

    func testLogSurvivesReopeningAndExportsInOrder() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        DiagnosticLog(directory: directory).record("first")
        let reopened = DiagnosticLog(directory: directory)
        reopened.record("second")
        let text = try String(contentsOf: reopened.export(), encoding: .utf8)
        XCTAssertTrue(text.contains("first"))
        XCTAssertTrue(text.contains("second"))
        let lines = text.split(separator: "\n").dropFirst()
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertNotNil(entry["time"])
            XCTAssertNotNil(entry["launch"])
        }
    }

    func testRotationRetainsOnlyTwoBoundedFiles() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory, maximumBytes: 400)
        for number in 0..<30 { log.record("event", fields: ["number": String(number)]) }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["current.jsonl", "previous.jsonl"])
        for file in files { XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 400) }
        XCTAssertTrue(try String(contentsOf: log.export(), encoding: .utf8).contains("29"))
    }

    func testRequestMetadataExcludesTokensQueriesBodiesAndSessionIDs() {
        let id = UUID().uuidString
        var request = URLRequest(url: URL(string: "https://example.com/sessions/\(id)/end?token=secret-query")!)
        request.httpMethod = "POST"
        request.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("private conversation".utf8)
        let fields = DiagnosticLog.requestFields(request)
        XCTAssertEqual(fields, ["method": "POST", "host": "example.com", "route": "/sessions/{id}/end"])
    }

    func testErrorLogOmitsDescriptionsAndSensitiveUserInfo() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        log.failure("failed", error: NSError(domain: NSURLErrorDomain, code: -1001,
            userInfo: [NSLocalizedDescriptionKey: "secret-token", NSURLErrorFailingURLStringErrorKey: "https://example.com?secret"]))
        let text = try String(contentsOf: log.export(), encoding: .utf8)
        XCTAssertTrue(text.contains("-1001"))
        XCTAssertFalse(text.contains("secret"))
    }

    func testProviderErrorKeepsCodeWithoutMessageOrTranscript() throws {
        let data = Data("""
        {"type":"error","error":{"code":"invalid_request","message":"secret conversation"},"transcript":"private"}
        """.utf8)
        XCTAssertEqual(RealtimeEvent(data: data)?.errorCode, "invalid_request")
    }
}
