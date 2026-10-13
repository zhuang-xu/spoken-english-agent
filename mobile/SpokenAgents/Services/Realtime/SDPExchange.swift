import Foundation

struct HTTPSDPExchanger {
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func exchange(offer: String, url: URL, credential: String) async throws -> String {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.path == "/openai/v1/realtime/calls", url.query == nil, url.fragment == nil else {
            throw RealtimeFailure.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(offer.utf8)
        let (data, response) = try await DiagnosticHTTP.send(request, using: session)
        guard response.statusCode == 200 || response.statusCode == 201 else {
            throw RealtimeFailure.providerStatus(response.statusCode)
        }
        guard let answer = String(data: data, encoding: .utf8), answer.hasPrefix("v=0") else {
            throw RealtimeFailure.invalidAnswer
        }
        return answer
    }
}
