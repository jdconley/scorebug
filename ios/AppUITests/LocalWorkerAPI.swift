import CryptoKit
import XCTest

/// The local Worker's API (ios/AppUITests/LocalWorker), called from the test runner by the screen
/// tour and the store media tests: who the stand-in Google signs in as, and team setup.
extension XCTestCase {
    var localWorker: URL {
        URL(string: ProcessInfo.processInfo.environment["SCOREBUG_TEST_API_URL"] ?? "http://127.0.0.1:8787")!
    }

    func identity(_ email: String, name: String) throws {
        _ = try request("POST", "/dev/identity", body: ["email": email, "name": name])
    }

    /// Runs the sign-in redirect chain without a browser and returns a session token.
    func apiSignIn(_ email: String, name: String, invite: String? = nil) throws -> String {
        try identity(email, name: name)
        let verifier = String(repeating: "v", count: 43) + String(Int.random(in: 1000...9999))
        let challenge = Self.challenge(verifier)
        var components = URLComponents(url: localWorker.appendingPathComponent("v1/auth/google/start"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "challenge", value: challenge)] + (invite.map { [URLQueryItem(name: "invite", value: $0)] } ?? [])
        var location = try redirect(components.url!)
        while location.scheme != "scorebug" { location = try redirect(location) }
        let ticket = try XCTUnwrap(URLComponents(url: location, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ticket" }?.value,
                                   "sign-in for \(email) ended at \(location)")
        let session = try request("POST", "/v1/auth/session", body: ["ticket": ticket, "verifier": verifier])
        return try XCTUnwrap(session["token"] as? String)
    }

    func call(_ method: String, _ path: String, token: String, body: [String: Any]) throws -> [String: Any] {
        try request(method, path, token: token, body: body)
    }

    func request(_ method: String, _ path: String, token: String? = nil, body: [String: Any]? = nil) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: path, relativeTo: localWorker)!)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try send(request, follow: true)
        XCTAssertLessThan(response.statusCode, 400, "\(method) \(path): \(String(decoding: data, as: UTF8.self))")
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func redirect(_ url: URL) throws -> URL {
        let (_, response) = try send(URLRequest(url: url), follow: false)
        let location = try XCTUnwrap(response.value(forHTTPHeaderField: "Location"), "no redirect from \(url)")
        return try XCTUnwrap(URL(string: location, relativeTo: url)?.absoluteURL)
    }

    func send(_ request: URLRequest, follow: Bool) throws -> (Data, HTTPURLResponse) {
        let session = follow ? URLSession.shared : URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        var result: Result<(Data, HTTPURLResponse), Error>?
        let done = expectation(description: "request")
        session.dataTask(with: request) { data, response, error in
            if let data, let response = response as? HTTPURLResponse { result = .success((data, response)) }
            else { result = .failure(error ?? URLError(.badServerResponse)) }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 20)
        return try XCTUnwrap(result).get()
    }

    static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
