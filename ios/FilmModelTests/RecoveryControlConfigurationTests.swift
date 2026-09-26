import Foundation
import XCTest

final class RecoveryControlConfigurationTests: XCTestCase {
    private func environment(host: String = "127.0.0.1", apiHost: String = "192.168.1.130") -> [String: String] {
        ["SCOREBUG_RECOVERY_CONTROL_URL": "http://\(host):8123/",
         "SCOREBUG_RECOVERY_CONTROL_TOKEN": String(repeating: "a", count: 64),
         "SCOREBUG_RECOVERY_RUN_ID": "11111111-2222-4333-8444-555555555555",
         "SCOREBUG_DEVICE_API_URL": "http://\(apiHost):8124"]
    }

    func testLoopbackRemainsDefaultAndPreservesCredentials() throws {
        let env = environment()
        let configuration = try RecoveryControlConfiguration(environment: env)
        XCTAssertEqual(configuration.endpoint.absoluteString, env["SCOREBUG_RECOVERY_CONTROL_URL"])
        XCTAssertEqual(configuration.token, env["SCOREBUG_RECOVERY_CONTROL_TOKEN"])
        XCTAssertEqual(configuration.runID, env["SCOREBUG_RECOVERY_RUN_ID"])
        var withoutAPI = env; withoutAPI.removeValue(forKey: "SCOREBUG_DEVICE_API_URL")
        XCTAssertNoThrow(try RecoveryControlConfiguration(environment: withoutAPI))
    }

    func testLANRequiresExplicitOptInAndExactPrivateAPIHost() throws {
        for host in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.130"] {
            let env = environment(host: host, apiHost: host)
            XCTAssertThrowsError(try RecoveryControlConfiguration(environment: env), host)
            let configuration = try RecoveryControlConfiguration(environment: env, allowLAN: true)
            XCTAssertEqual(configuration.endpoint.host, host)
        }
        XCTAssertThrowsError(try RecoveryControlConfiguration(environment: environment(host: "192.168.1.131"), allowLAN: true))
        var missingAPI = environment(host: "192.168.1.130")
        missingAPI.removeValue(forKey: "SCOREBUG_DEVICE_API_URL")
        XCTAssertThrowsError(try RecoveryControlConfiguration(environment: missingAPI, allowLAN: true))
    }

    func testRejectsNoncanonicalOrNonprivateLANHostsEvenWhenAPIHostMatches() {
        for host in ["0.0.0.0", "8.8.8.8", "localhost", "example.local", "172.15.0.1", "172.32.0.1",
                     "192.169.1.1", "192.168.001.130", "10.1", "0x0a000001", "167772161", "[::1]", "%31%30.0.0.1"] {
            XCTAssertThrowsError(try RecoveryControlConfiguration(environment: environment(host: host, apiHost: host), allowLAN: true), host)
        }
    }

    func testRejectsEndpointDecorationsAndInvalidPorts() {
        for endpoint in ["https://127.0.0.1:8123", "http://127.0.0.1", "http://127.0.0.1:0",
                         "http://127.0.0.1:65536", "http://user@127.0.0.1:8123", "http://127.0.0.1:8123/constrain",
                         "http://127.0.0.1:8123/?x=1", "http://127.0.0.1:8123/#x", "http://%31%32%37.0.0.1:8123"] {
            var env = environment(); env["SCOREBUG_RECOVERY_CONTROL_URL"] = endpoint
            XCTAssertThrowsError(try RecoveryControlConfiguration(environment: env, allowLAN: true), endpoint)
        }
        for api in ["http://user@192.168.1.130:8124", "http://192.168.1.130:8124/?x=1",
                    "http://192.168.1.130:8124/#x", "ftp://192.168.1.130", "http://%31%39%32.168.1.130"] {
            var env = environment(host: "192.168.1.130"); env["SCOREBUG_DEVICE_API_URL"] = api
            XCTAssertThrowsError(try RecoveryControlConfiguration(environment: env, allowLAN: true), api)
        }
    }

    func testRejectsMissingOrMalformedCredentialsWithoutIncludingThemInError() {
        for (key, values) in [
            ("SCOREBUG_RECOVERY_CONTROL_TOKEN", ["", String(repeating: "a", count: 63), String(repeating: "A", count: 64), String(repeating: "g", count: 64)]),
            ("SCOREBUG_RECOVERY_RUN_ID", ["", "not-a-uuid", "11111111-2222-4333-8444-55555555555"])
        ] {
            var missing = environment(); missing.removeValue(forKey: key)
            XCTAssertThrowsError(try RecoveryControlConfiguration(environment: missing))
            for value in values {
                var env = environment(); env[key] = value
                XCTAssertThrowsError(try RecoveryControlConfiguration(environment: env)) { error in
                    XCTAssertEqual(String(describing: error), "invalid")
                }
            }
        }
    }
}
