import Foundation

struct RealtimeEvent: Equatable, Sendable {
    let type: String
    let itemID: String?
    let transcript: String?
    let turnDetectionDisabled: Bool?
    let contentIndex: Int?
    let responseID: String?
    let errorCode: String?

    init(type: String, itemID: String? = nil, transcript: String? = nil, turnDetectionDisabled: Bool? = nil,
         contentIndex: Int? = nil, responseID: String? = nil, errorCode: String? = nil) {
        self.type = type
        self.itemID = itemID
        self.transcript = transcript
        self.turnDetectionDisabled = turnDetectionDisabled
        self.contentIndex = contentIndex
        self.responseID = responseID
        self.errorCode = errorCode
    }

    init?(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        let session = json["session"] as? [String: Any]
        let audio = session?["audio"] as? [String: Any]
        let input = audio?["input"] as? [String: Any]
        let disabled = input?["turn_detection"] is NSNull
        let providerError = json["error"] as? [String: Any]
        let rawCode = providerError?["code"] as? String
        let code = rawCode.flatMap { value in
            value.count <= 100 && value.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil ? value : nil
        }
        self.init(type: type, itemID: json["item_id"] as? String,
                  transcript: json["transcript"] as? String,
                  turnDetectionDisabled: type == "session.updated" ? disabled : nil,
                  contentIndex: json["content_index"] as? Int, responseID: json["response_id"] as? String,
                  errorCode: code)
    }
}

enum RealtimeFailure: Error, Equatable {
    case invalidURL
    case invalidAnswer
    case providerStatus(Int)
    case channelUnavailable
    case connectionTimedOut
    case dependencyUnavailable
    case microphoneStartupFailed
}

@MainActor protocol RealtimeTransporting: AnyObject {
    var onEvent: ((RealtimeEvent) -> Void)? { get set }
    func connect(url: URL, credential: String) async throws
    func send(_ payload: [String: Any]) throws
    func setInputEnabled(_ enabled: Bool)
    func startInput() throws
    func setSpeakerEnabled(_ enabled: Bool) throws
    func close()
}
