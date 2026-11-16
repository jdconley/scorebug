import XCTest
@testable import ScorebugCore

final class ScorebugLinkTests: XCTestCase {
    private let setupCode = "abcDEF123_-xyzABC456789q"

    func testConnectLinkDecodesPercentEncodedServerAndCode() throws {
        let link = try XCTUnwrap(ScorebugLink(string: "scorebug://connect?server=https%3A%2F%2Fscore.example.com%2Fbase&code=\(setupCode)"))
        XCTAssertEqual(link, .connect(server: try ScoringEndpoint("https://score.example.com/base"), code: setupCode))
        XCTAssertEqual(link.server.url.absoluteString, "https://score.example.com/base")
    }

    func testJoinLinkNormalizesInviteCode() throws {
        let link = try XCTUnwrap(ScorebugLink(string: "  scorebug://join?server=https%3A%2F%2Fscore.example.com&code=k7p4qx \n"))
        XCTAssertEqual(link, .join(server: try ScoringEndpoint("https://score.example.com"), code: "K7P4QX"))
    }

    func testRejectsOtherSchemesActionsAndUnsafeServers() {
        let bad = [
            "https://score.example.com/connect?server=https%3A%2F%2Fa.example&code=\(setupCode)",
            "scorebug://pair?server=https%3A%2F%2Fa.example&code=\(setupCode)",
            "scorebug://connect?server=http%3A%2F%2Fpublic.example.com&code=\(setupCode)", // plain HTTP off-LAN
            "scorebug://connect?server=https%3A%2F%2Fuser%3Apw%40a.example&code=\(setupCode)",
            "scorebug://connect?code=\(setupCode)",
            "scorebug://connect?server=https%3A%2F%2Fa.example",
            "scorebug://connect?server=https%3A%2F%2Fa.example&code=short",
            "scorebug://connect?server=https%3A%2F%2Fa.example&code=\(setupCode)&code=other\(setupCode)",
            "scorebug://join?server=https%3A%2F%2Fa.example&code=K7P4Q0", // 0 not in alphabet
            "scorebug://join?server=https%3A%2F%2Fa.example&code=K7P4QXY",
            "not a link",
        ]
        for text in bad { XCTAssertNil(ScorebugLink(string: text), text) }
    }

    func testLocalDevelopmentServerOverHTTPIsAccepted() throws {
        let link = try XCTUnwrap(ScorebugLink(string: "scorebug://connect?server=http%3A%2F%2F127.0.0.1%3A18787&code=\(setupCode)"))
        XCTAssertEqual(link.server.url.absoluteString, "http://127.0.0.1:18787")
    }

    func testInviteCodeNormalizationAndFormatting() {
        XCTAssertEqual(InviteCode.normalize("k7p-4qx"), "K7P4QX")
        XCTAssertEqual(InviteCode.normalize(" K7P 4QX "), "K7P4QX")
        XCTAssertNil(InviteCode.normalize("K7P-4QI"))
        XCTAssertNil(InviteCode.normalize("K7P"))
        XCTAssertEqual(InviteCode.format("k7p4qx"), "K7P-4QX")
    }

    func testJoinInputAcceptsLinkOrBareCode() throws {
        XCTAssertEqual(JoinInput("k7p-4qx"), .code("K7P4QX"))
        XCTAssertEqual(JoinInput("scorebug://join?server=https%3A%2F%2Fa.example&code=K7P4QX"),
                       .link(server: try ScoringEndpoint("https://a.example"), code: "K7P4QX"))
        XCTAssertNil(JoinInput("scorebug://connect?server=https%3A%2F%2Fa.example&code=\(setupCode)"))
        XCTAssertNil(JoinInput("hello"))
    }

    func testManualSetupCodeIgnoresSpaces() {
        XCTAssertEqual(ScorebugLink.normalizeSetupCode("abcd efgh ijkl"), "abcdefghijkl")
        XCTAssertNil(ScorebugLink.normalizeSetupCode("abc/defgh"))
    }
}
