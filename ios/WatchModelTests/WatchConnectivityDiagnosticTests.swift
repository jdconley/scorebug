import XCTest

final class WatchConnectivityDiagnosticTests: XCTestCase {
    func testDisabledProducesNoRows() {
        let diagnostic = WatchConnectivityDiagnostic(enabled: false)
        XCTAssertNil(diagnostic.record(.activateRequested, state: .init(activation: 0)))
    }
    func testClosedFieldsPreserveUnknownAndFalse() {
        let diagnostic = WatchConnectivityDiagnostic(enabled: true)
        let unknown = diagnostic.record(.activateRequested, state: .init(activation: 0)) ?? "missing"
        XCTAssertEqual(unknown, "v=1 seq=1 event=activateRequested kind=none activation=0 reachable=unknown paired=unknown installed=unknown error=none")
        let known = diagnostic.record(.publishRejected, kind: .notice,
            state: .init(activation: 2, reachable: false, paired: true, installed: false, errorCode: 7018)) ?? "missing"
        XCTAssertEqual(known, "v=1 seq=2 event=publishRejected kind=notice activation=2 reachable=false paired=true installed=false error=7018")
    }
    func testBoundedRowsAndSingleOverflow() {
        let diagnostic = WatchConnectivityDiagnostic(enabled: true)
        for i in 1...128 {
            XCTAssertTrue((diagnostic.record(.contextReceived, state: .init(activation: 2)) ?? "missing").contains("seq=\(i) "))
        }
        XCTAssertEqual(diagnostic.record(.contextReceived, state: .init(activation: 2)), "v=1 seq=129 event=overflow")
        XCTAssertNil(diagnostic.record(.contextReceived, state: .init(activation: 2)))
    }
    func testConcurrentCallbacksRemainBoundedAndUnique() {
        let diagnostic = WatchConnectivityDiagnostic(enabled: true)
        let lock = NSLock()
        var rows: [String] = []
        DispatchQueue.concurrentPerform(iterations: 512) { _ in
            if let row = diagnostic.record(.activationCompleted, state: .init(activation: 2)) {
                lock.lock(); rows.append(row); lock.unlock()
            }
        }
        XCTAssertEqual(rows.count, 129)
        XCTAssertEqual(Set(rows).count, 129)
        XCTAssertEqual(rows.filter { $0.contains("event=overflow") }.count, 1)
    }
}
