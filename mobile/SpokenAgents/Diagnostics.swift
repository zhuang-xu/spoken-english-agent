import Foundation
import OSLog

/// A bounded, persistent timeline. Callers supply metadata, never payloads or credentials.
final class DiagnosticLog {
    static let shared = DiagnosticLog()
    static let containerPath = "Library/Application Support/Diagnostics"
    private let directory: URL
    private let maximumBytes: Int
    private let lock = NSLock()
    private let launchID = UUID().uuidString
    private let console = Logger(subsystem: "com.zhuangxu.spokenagents.app", category: "Diagnostics")

    init(directory: URL? = nil, maximumBytes: Int = 1_000_000) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
        self.maximumBytes = maximumBytes
    }

    func record(_ event: String, fields: [String: String] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try prepareDirectory()
            let file = directory.appendingPathComponent("current.jsonl")
            let timestamp = ISO8601DateFormatter()
            timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let entry: [String: Any] = ["time": timestamp.string(from: Date()),
                                        "launch": launchID, "event": event, "fields": fields]
            var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            data.append(0x0a)
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size + data.count > maximumBytes {
                let previous = directory.appendingPathComponent("previous.jsonl")
                if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.moveItem(at: file, to: previous) }
            }
            if !FileManager.default.fileExists(atPath: file.path) {
                try Data().write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            console.info("\(event, privacy: .public)")
        } catch {
            // Diagnostics must never interrupt sign-in or a call.
            console.error("Diagnostic file write failed: \((error as NSError).code, privacy: .public)")
        }
    }

    func failure(_ event: String, error: Error, fields: [String: String] = [:]) {
        var metadata = fields
        let failure = error as NSError
        metadata["error_domain"] = failure.domain
        metadata["error_code"] = String(failure.code)
        if case BackendFailure.status(let status) = error { metadata["http_status"] = String(status) }
        if case RealtimeFailure.providerStatus(let status) = error { metadata["http_status"] = String(status) }
        if let realtime = error as? RealtimeFailure { metadata["realtime_error"] = String(describing: realtime) }
        if let decoding = error as? DecodingError {
            let context: DecodingError.Context
            switch decoding {
            case .keyNotFound(let key, let value):
                metadata["missing_key"] = key.stringValue; context = value
            case .typeMismatch(_, let value), .valueNotFound(_, let value), .dataCorrupted(let value): context = value
            @unknown default: record(event, fields: metadata); return
            }
            metadata["coding_path"] = context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        // Error descriptions/userInfo can contain tokens, URLs, and server payloads.
        record(event, fields: metadata)
    }

    func export() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        try prepareDirectory()
        var data = Data("Spoken Agents diagnostic timeline (UTC). Payloads and credentials are excluded.\n".utf8)
        for name in ["previous.jsonl", "current.jsonl"] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { data.append(try Data(contentsOf: url)) }
        }
        let result = directory.appendingPathComponent("diagnostics.txt")
        try data.write(to: result, options: [.atomic, .completeFileProtectionUnlessOpen])
        return result
    }

    static func requestFields(_ request: URLRequest) -> [String: String] {
        // Query strings, headers, bodies, and account/session identifiers are excluded.
        let route = (request.url?.path ?? "").split(separator: "/").map {
            UUID(uuidString: String($0)) == nil ? String($0) : "{id}"
        }.joined(separator: "/")
        return ["method": request.httpMethod ?? "GET", "host": request.url?.host ?? "", "route": "/" + route]
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }
}

enum DiagnosticHTTP {
    static func send(_ request: URLRequest, using session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let start = Date()
        var fields = DiagnosticLog.requestFields(request)
        fields["request"] = UUID().uuidString
        DiagnosticLog.shared.record("http.start", fields: fields)
        do {
            let (data, raw) = try await session.data(for: request)
            guard let response = raw as? HTTPURLResponse else { throw BackendFailure.invalidResponse }
            fields["http_status"] = String(response.statusCode)
            fields["duration_ms"] = String(Int(Date().timeIntervalSince(start) * 1000))
            fields["response_bytes"] = String(data.count)
            DiagnosticLog.shared.record("http.response", fields: fields)
            return (data, response)
        } catch {
            fields["duration_ms"] = String(Int(Date().timeIntervalSince(start) * 1000))
            DiagnosticLog.shared.failure("http.failure", error: error, fields: fields)
            throw error
        }
    }
}
