import XCTest
@testable import ScorebugCore

final class ScoringEndpointTests: XCTestCase {
    func testAcceptsHTTPSControlPlaneAndTrimsPastedWhitespace() throws {
        let endpoint = try ScoringEndpoint("  https://api.scorebug.live\n")
        XCTAssertEqual(endpoint.url.absoluteString, "https://api.scorebug.live")
    }

    func testAcceptsLocalDevelopmentAddressesWithPorts() throws {
        for address in ["http://localhost:3000", "http://127.0.0.1:3000", "http://192.168.1.20:3000", "http://[::1]:3000", "http://scorebug.local:3000", "http://10.1.2.3:3000", "http://172.16.0.1:3000"] {
            XCTAssertEqual(try ScoringEndpoint(address).url.absoluteString, address)
        }
    }

    func testRejectsMissingHostOrNonHTTPTransports() {
        for address in ["", "localhost:3000", "/games", "https://", "file:///tmp/server", "ws://localhost:3000"] {
            XCTAssertThrowsError(try ScoringEndpoint(address), address)
        }
    }

    func testRejectsInsecurePublicServers() {
        for address in ["http://example.com", "http://8.8.8.8", "http://172.32.0.1", "http://192.168.999.1"] {
            XCTAssertThrowsError(try ScoringEndpoint(address), address)
        }
    }

    func testRejectsEmbeddedCredentialsQueryAndFragment() {
        for address in ["https://user:secret@example.com", "https://example.com?token=secret", "https://example.com#game"] {
            XCTAssertThrowsError(try ScoringEndpoint(address), address)
        }
    }

    func testAcceptsBasePathAndRejectsInvalidPortOrHostWhitespace() throws {
        XCTAssertEqual(try ScoringEndpoint("https://example.com/api/").url.path, "/api")
        for address in ["http://localhost:0", "http://localhost:65536", "http://local host:3000"] {
            XCTAssertThrowsError(try ScoringEndpoint(address), address)
        }
    }
}
