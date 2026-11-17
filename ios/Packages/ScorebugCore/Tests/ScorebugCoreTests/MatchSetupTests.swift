import XCTest
@testable import ScorebugCore

final class MatchSetupTests: XCTestCase {
    func testShortNameDerivation() {
        XCTAssertEqual(ShortName.derive(from: "Cascade 14 Black"), "CASCADE")
        XCTAssertEqual(ShortName.derive(from: "Summit"), "SUMMIT")
        XCTAssertEqual(ShortName.derive(from: "Lakeside"), "LAKESIDE")
        XCTAssertEqual(ShortName.derive(from: "Northgate Volleyball"), "NORTHGAT")
        XCTAssertEqual(ShortName.derive(from: "  Riverbend   Elite "), "RIVERBEN")
        XCTAssertEqual(ShortName.derive(from: "Puget Sound"), "PUGET")
        XCTAssertEqual(ShortName.derive(from: "SJ Storm"), "SJ STORM")
        XCTAssertEqual(ShortName.derive(from: ""), "")
        XCTAssertEqual(ShortName.derive(from: "Supercalifragilistic"), "SUPERCAL")
    }

    func testShortNameFollowsNameUntilEdited() {
        var team = TeamDraft(color: "#2563eb")
        team.setName("Cascade 14 Black")
        XCTAssertEqual(team.shortName, "CASCADE")
        team.setShortName("cas14blackx")
        XCTAssertEqual(team.shortName, "CAS14BLA", "uppercased and capped at 8")
        team.setName("Cascade 15 Red")
        XCTAssertEqual(team.shortName, "CAS14BLA", "a hand edit sticks")
        team.setShortName("")
        XCTAssertEqual(team.shortName, "CASCADE", "clearing follows the name again")
        team.setName("Summit")
        XCTAssertEqual(team.shortName, "SUMMIT")
    }

    func testRememberedShortNameIsNotTreatedAsEdited() {
        var team = TeamDraft(name: "Cascade 14 Black", shortName: "CASCADE", color: "#2563eb")
        team.setName("Cascade 15 Red")
        XCTAssertEqual(team.shortName, "CASCADE")
        var custom = TeamDraft(name: "Cascade 14 Black", shortName: "C14B", color: "#2563eb")
        custom.setName("Cascade 15 Red")
        XCTAssertEqual(custom.shortName, "C14B")
    }

    func testValidation() {
        var draft = NewMatchDraft()
        XCTAssertEqual(draft.issues, [.missingName(.team1), .invalidShortName(.team1),
                                      .missingName(.team2), .invalidShortName(.team2)])
        draft.team1.setName("Cascade")
        draft.team2.setName("Cascade")
        XCTAssertEqual(draft.issues, [.sameShortName])
        draft.team2.setName("Summit")
        XCTAssertTrue(draft.isValid)
        draft.team2.color = "blue"
        XCTAssertEqual(draft.issues, [.invalidColor(.team2)])
        XCTAssertFalse(NewMatchIssue.sameShortName.message.lowercased().contains("home"))
        for issue in [NewMatchIssue.missingName(.team1), .invalidShortName(.team2), .invalidColor(.team1)] {
            XCTAssertFalse(issue.message.lowercased().contains("home") || issue.message.lowercased().contains("away"))
        }
    }

    func testCreationMapsTeam1ToHomeAndOmitsUnsetOptions() throws {
        var draft = NewMatchDraft(format: .bestOf5, style: .setCard)
        draft.team1.setName(" Cascade 14 Black ")
        draft.team2.setName("Summit")
        draft.team2.color = "#F97316"
        let creation = draft.creation(id: "m1", deviceId: "d1", recordOnly: false)
        XCTAssertEqual(creation.teams.home, MatchTeam(name: "Cascade 14 Black", shortName: "CASCADE", color: "#2563eb"))
        XCTAssertEqual(creation.teams.away, MatchTeam(name: "Summit", shortName: "SUMMIT", color: "#f97316"))
        XCTAssertEqual(creation.rules, MatchRules(bestOf: 5, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: nil))
        let streamed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(creation)) as? [String: Any]
        XCTAssertEqual(Set(try XCTUnwrap(streamed).keys), ["id", "deviceId", "teams", "rules", "scorebugStyle"])
        XCTAssertEqual(streamed?["scorebugStyle"] as? String, "setCard")

        let recordOnly = draft.creation(id: "m1", deviceId: "d1", recordOnly: true)
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recordOnly)) as? [String: Any]
        XCTAssertEqual(Set(try XCTUnwrap(body).keys), ["id", "deviceId", "teams", "rules", "scorebugStyle", "recordOnly"])
        XCTAssertEqual(body?["recordOnly"] as? Bool, true)
    }

    func testPaletteContrast() {
        XCTAssertTrue(TeamPalette.prefersDarkText(on: "#eab308"))
        XCTAssertTrue(TeamPalette.prefersDarkText(on: "#f2f4f7"))
        XCTAssertFalse(TeamPalette.prefersDarkText(on: "#2563eb"))
        XCTAssertFalse(TeamPalette.prefersDarkText(on: "#111827"))
        XCTAssertTrue(TeamPalette.swatches.allSatisfy { TeamPalette.isValidHex($0.hex) })
    }

    func testDraftPersistsAsJSON() throws {
        var draft = NewMatchDraft(recordIn4K: true)
        draft.team1.setName("Cascade")
        draft.team1.setShortName("CAS")
        let decoded = try JSONDecoder().decode(NewMatchDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(decoded, draft)
    }
}
