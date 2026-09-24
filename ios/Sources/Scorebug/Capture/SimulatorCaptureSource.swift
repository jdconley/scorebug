#if DEBUG
import Foundation
import ScorebugMedia

/// App.swift calls this only in a DEBUG Simulator build. Files are staged in the
/// app's container, never bundled; any requested but invalid setup fails closed.
enum SimulatorCaptureSource {
    static func make(environment: [String: String], supportDirectory: URL) throws -> any CaptureSource {
        guard let flag = environment["SCOREBUG_TEST_FILE_CAPTURE"] else {
            return FixtureCameraSource(failAfterFrames: Int(environment["SCOREBUG_FIXTURE_FAIL_AFTER"] ?? ""),
                                       motionFlag: environment["SCOREBUG_TEST_MOTION_FIXTURE"])
        }
        guard flag == "1", environment["SCOREBUG_TEST_MOTION_FIXTURE"] == nil,
              environment["SCOREBUG_FIXTURE_FAIL_AFTER"] == nil else { throw ConfigurationError.invalid }
        return FileFixtureCameraSource(url: supportDirectory.appendingPathComponent("Scorebug/QA/input.mov"))
    }
    private enum ConfigurationError: Error { case invalid }
}
#endif
