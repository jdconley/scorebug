import XCTest
@testable import ScorebugCore

final class ScorebugLinkTests: XCTestCase {
    func testTeamInviteLinkNormalizesCode() {
        XCTAssertEqual(ScorebugLink(string: " https://scorebug.live/invite/abcd2345 \n"), .teamInvite(code: "ABCD2345"))
        XCTAssertEqual(ScorebugLink(string: "https://scorebug.live/invite/ABCD-2345"), .teamInvite(code: "ABCD2345"))
        XCTAssertEqual(ScorebugLink(string: "https://www.scorebug.live/invite/ABCD2345/"), .teamInvite(code: "ABCD2345"))
    }

    func testMatchJoinLinkNormalizesCode() {
        XCTAssertEqual(ScorebugLink(string: "https://scorebug.live/join/k7p4qx"), .matchJoin(code: "K7P4QX"))
        XCTAssertEqual(ScorebugLink(string: "https://SCOREBUG.LIVE/join/K7P-4QX?utm=x"), .matchJoin(code: "K7P4QX"))
    }

    func testRejectsOtherHostsPathsCodesAndOldLinks() {
        let bad = [
            "https://evil.example/invite/ABCD2345",
            "https://scorebug.live.evil.example/join/K7P4QX",
            "http://scorebug.live/join/K7P4QX", // plain HTTP off-LAN
            "https://user:pw@scorebug.live/join/K7P4QX",
            "https://scorebug.live/join/K7P4Q0", // 0 not in alphabet
            "https://scorebug.live/join/K7P4QXY",
            "https://scorebug.live/invite/ABCD234", // 7 characters
            "https://scorebug.live/invite/ABCD2345/extra",
            "https://scorebug.live/admin",
            "https://scorebug.live/",
            "scorebug://join?server=https%3A%2F%2Fscorebug.live&code=K7P4QX",
            "scorebug://connect?server=https%3A%2F%2Fa.example&code=abcDEF123_-xyzABC456789q",
            "scorebug://auth?status=ok",
            "not a link",
        ]
        for text in bad { XCTAssertNil(ScorebugLink(string: text), text) }
    }

    func testDebugServerHostIsTrustedOverLocalHTTP() throws {
        let hosts = ScorebugLink.hosts(for: try ScoringEndpoint("http://localhost:8787"))
        XCTAssertEqual(hosts, ["scorebug.live", "localhost"])
        XCTAssertEqual(ScorebugLink(string: "http://localhost:8787/join/K7P4QX", hosts: hosts), .matchJoin(code: "K7P4QX"))
        XCTAssertNil(ScorebugLink(string: "http://localhost:8787/join/K7P4QX"))
    }

    func testMatchCodeFromLinkOrBareCode() {
        XCTAssertEqual(ScorebugLink.matchCode(from: "k7p-4qx"), "K7P4QX")
        XCTAssertEqual(ScorebugLink.matchCode(from: "https://scorebug.live/join/K7P4QX"), "K7P4QX")
        XCTAssertNil(ScorebugLink.matchCode(from: "https://scorebug.live/invite/ABCD2345"))
        XCTAssertNil(ScorebugLink.matchCode(from: "hello"))
    }

    func testInviteCodeNormalizationAndFormatting() {
        XCTAssertEqual(InviteCode.normalize("k7p-4qx"), "K7P4QX")
        XCTAssertEqual(InviteCode.normalize(" K7P 4QX "), "K7P4QX")
        XCTAssertNil(InviteCode.normalize("K7P-4QI"))
        XCTAssertNil(InviteCode.normalize("K7P"))
        XCTAssertEqual(InviteCode.format("k7p4qx"), "K7P-4QX")
        XCTAssertEqual(TeamInviteCode.normalize("abcd-2345"), "ABCD2345")
        XCTAssertNil(TeamInviteCode.normalize("ABCD-234O"))
    }
}
