import Foundation
import XCTest
@testable import ScorebugCore

final class DecoderDeliveryHTTPTests: XCTestCase {
    func testLegacyFullAndCursorRequestsUseScopedHeaderAndUncachedQueries() async throws {
        let credential = MatchCredential(gameId: "match", deviceId: "phone", role: .capture, token: "scoped-secret")
        let response = WorkerMediaStatusResponse(status: .init(gameId: "match", generation: 1, workerId: nil,
            state: .unknown, observation: nil, observedAt: nil, expiresAt: nil), serverTime: "2040-01-01T00:00:00Z")
        let data = try JSONEncoder().encode(response)
        let requests: [DecoderDeliveryRequest?] = [nil, .full, .after(.init(scopeID: DecoderDeliveryPacketTests.scope, lastOrdinal: 9_007_199_254_740_991))]
        for (index, option) in requests.enumerated() {
            let client = MatchHTTPClient(endpoint: try ScoringEndpoint("https://example.com/base"), transport: { request in
                XCTAssertEqual(request.url?.path, "/base/v1/matches/match/media/status")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer scoped-secret")
                XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache, no-store")
                let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
                XCTAssertEqual(q.count, index == 0 ? 0 : index == 1 ? 1 : 3)
                if index > 0 { XCTAssertEqual(q.first?.value, "decoder-delivery-delta-v1") }
                if index == 2 { XCTAssertEqual(q.last?.value, "9007199254740991") }
                XCTAssertFalse(request.url!.absoluteString.contains("secret"))
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let result = try await client.workerStatus(credential: credential, delivery: option)
            XCTAssertEqual(result, response)
        }
    }
    func testInvalidCursorNeverReachesTransport() async throws {
        let client = MatchHTTPClient(endpoint: try ScoringEndpoint("https://example.com"), transport: { _ in
            XCTFail("Invalid cursor sent");throw MatchClientError.invalidResponse
        })
        for cursor in [DecoderDeliveryCursor(scopeID: "bad&token=secret", lastOrdinal: 1), .init(scopeID: DecoderDeliveryPacketTests.scope, lastOrdinal: -1), .init(scopeID: DecoderDeliveryPacketTests.scope, lastOrdinal: Int64.max)] {
            do {
                _ = try await client.workerStatus(credential: .init(gameId: "match", deviceId: "phone", role: .capture, token: "test"), delivery: .after(cursor))
                XCTFail("Invalid cursor accepted")
            } catch { XCTAssertEqual(error as? MatchClientError, .invalidIdentifier) }
        }
    }
}
