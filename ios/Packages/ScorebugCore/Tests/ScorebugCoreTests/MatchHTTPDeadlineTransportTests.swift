import Foundation
import XCTest
@testable import ScorebugCore

final class MatchHTTPDeadlineTransportTests: XCTestCase {
    private func request(timeout: TimeInterval = 20) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://example.com/control/v1/matches/game/commands")!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer watch-only-token", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"commandId":"original-command"}"#.utf8)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }
    private func owner(_ http: DeadlineHTTP, _ sleeper: DeadlineSleeper, _ clock: DeadlineClock,
                       timeout: TimeInterval = 2) -> MatchHTTPDeadlineTransport {
        MatchHTTPDeadlineTransport(timeout: timeout, now: { clock.read() }, sleep: { try await sleeper.sleep($0) }, transport: { try await http.send($0) })
    }
    private func timedOut(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual((error as? URLError)?.code, .timedOut, file: file, line: line)
    }

    func testOnTimeResponsePreservesRequestAndJoinsCancelledTimer() async throws {
        for inactivity in [20.0, 0.5] {
            let http = DeadlineHTTP(), sleeper = DeadlineSleeper(), clock = DeadlineClock()
            let original = request(timeout: inactivity)
            let transport = owner(http, sleeper, clock)
            let task = Task { try await transport.send(original) }
            await http.waitUntilStarted(); await sleeper.waitUntilStarted()
            clock.set(101)
            await http.complete(.success(DeadlineHTTP.response))
            let response = try await task.value
            XCTAssertEqual(response.0, DeadlineHTTP.response.0)
            XCTAssertEqual(response.1.url, DeadlineHTTP.response.1.url)
            let sent = await http.requests
            XCTAssertEqual(sent.count, 1)
            XCTAssertEqual(sent[0].url, original.url)
            XCTAssertEqual(sent[0].httpMethod, original.httpMethod)
            XCTAssertEqual(sent[0].allHTTPHeaderFields, original.allHTTPHeaderFields)
            XCTAssertEqual(sent[0].httpBody, original.httpBody)
            XCTAssertEqual(sent[0].cachePolicy, original.cachePolicy)
            XCTAssertEqual(sent[0].timeoutInterval, min(2, inactivity))
            XCTAssertEqual(original.timeoutInterval, inactivity)
            let timerCancelled = await sleeper.cancelled
            let timerActive = await sleeper.activeCount
            XCTAssertTrue(timerCancelled); XCTAssertEqual(timerActive, 0)
        }
    }

    func testUnderlyingHTTPFailuresPropagateAfterTimerJoin() async throws {
        let failures: [Error] = [URLError(.notConnectedToInternet), DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "fixture decoding error"))]
        for error in failures {
            let http = DeadlineHTTP(), sleeper = DeadlineSleeper(), clock = DeadlineClock()
            let transport = owner(http, sleeper, clock), request = request()
            let task = Task { try await transport.send(request) }
            await http.waitUntilStarted(); await sleeper.waitUntilStarted()
            await http.complete(.failure(error))
            do { _ = try await task.value; XCTFail("Expected original transport failure") }
            catch let observed as URLError { XCTAssertEqual(observed.code, .notConnectedToInternet) }
            catch { XCTAssertTrue(error is DecodingError) }
            let timerActive = await sleeper.activeCount
            XCTAssertEqual(timerActive, 0)
        }
    }

    func testDeadlineCancelsAndJoinsCancellationIgnoringHTTPBeforeReturning() async throws {
        let http = DeadlineHTTP(), sleeper = DeadlineSleeper(), clock = DeadlineClock(), completion = DeadlineCompletion()
        let transport = owner(http, sleeper, clock), request = request()
        let task = Task { () -> Result<(Data, URLResponse), Error> in
            let result: Result<(Data, URLResponse), Error>
            do { result = .success(try await transport.send(request)) } catch { result = .failure(error) }
            await completion.mark(); return result
        }
        await http.waitUntilStarted(); await sleeper.waitUntilStarted()
        clock.set(102); await sleeper.wake()
        await http.waitUntilCancelled()
        let returned = await completion.finished
        XCTAssertFalse(returned, "Cancellation is not an HTTP join")
        await http.complete(.success(DeadlineHTTP.response))
        switch await task.value { case .success: XCTFail("Expected timeout"); case .failure(let error): timedOut(error) }
        let calls = await http.requests
        XCTAssertEqual(calls.count, 1)
    }

    func testLateHTTPResponseFailsAbsoluteDeadlineBeforeTimerExecution() async throws {
        for time in [102.0, 103.0] {
            let http = DeadlineHTTP(), sleeper = DeadlineSleeper(), clock = DeadlineClock()
            let transport = owner(http, sleeper, clock), request = request()
            let task = Task { try await transport.send(request) }
            await http.waitUntilStarted(); await sleeper.waitUntilStarted()
            clock.set(time)
            await http.complete(.success(DeadlineHTTP.response))
            do { _ = try await task.value; XCTFail("Late success must not escape") }
            catch { timedOut(error) }
            let cancelled = await sleeper.cancelled
            XCTAssertTrue(cancelled)
        }
    }

    func testEarlyTimerWakeSleepsOnlyRemainingAbsoluteBudget() async throws {
        let http = DeadlineHTTP(), sleeper = DeadlineSleeper(), clock = DeadlineClock()
        let transport = owner(http, sleeper, clock), request = request()
        let task = Task { try await transport.send(request) }
        await http.waitUntilStarted(); await sleeper.waitUntilStarted()
        clock.set(100.5); await sleeper.wake()
        await sleeper.waitUntilStarted(count: 2)
        let delays = await sleeper.delays
        XCTAssertEqual(delays, [2, 1.5])
        clock.set(101)
        await http.complete(.success(DeadlineHTTP.response))
        _ = try await task.value
    }

    func testPreCancellationStartsNeitherHTTPNorTimer() async throws {
        let http = DeadlineHTTP(), sleeper = DeadlineSleeper(), clock = DeadlineClock()
        let transport = owner(http, sleeper, clock), request = request()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.send(request)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requests = await http.requests, delays = await sleeper.delays
        XCTAssertTrue(requests.isEmpty); XCTAssertTrue(delays.isEmpty)
    }

    func testParentCancellationJoinsHTTPAndRejectsItsLateSuccess() async throws {
        let http = DeadlineHTTP(), sleeper = DeadlineSleeper(), clock = DeadlineClock(), completion = DeadlineCompletion()
        let transport = owner(http, sleeper, clock), request = request()
        let task = Task { () -> Result<(Data, URLResponse), Error> in
            let result: Result<(Data, URLResponse), Error>
            do { result = .success(try await transport.send(request)) } catch { result = .failure(error) }
            await completion.mark(); return result
        }
        await http.waitUntilStarted(); await sleeper.waitUntilStarted()
        task.cancel()
        await http.waitUntilCancelled()
        let returned = await completion.finished
        XCTAssertFalse(returned)
        await http.complete(.success(DeadlineHTTP.response))
        switch await task.value { case .success: XCTFail("Expected cancellation"); case .failure(let error): XCTAssertTrue(error is CancellationError) }
        let activeTimers = await sleeper.activeCount
        XCTAssertEqual(activeTimers, 0)
    }

    func testInvalidConfigurationAndInitialClockFailWithoutDispatch() async throws {
        let invalid: [TimeInterval] = [0, -1, .nan, .infinity, -.infinity]
        for timeout in invalid {
            let http = DeadlineHTTP(), sleeper = DeadlineSleeper(), clock = DeadlineClock()
            do { _ = try await owner(http, sleeper, clock, timeout: timeout).send(request()); XCTFail("Expected invalid timeout") }
            catch { timedOut(error) }
            let requests = await http.requests, delays = await sleeper.delays
            XCTAssertTrue(requests.isEmpty); XCTAssertTrue(delays.isEmpty)
        }
        for time in [TimeInterval.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            let http = DeadlineHTTP(), sleeper = DeadlineSleeper(), clock = DeadlineClock()
            clock.set(time)
            do { _ = try await owner(http, sleeper, clock, timeout: .greatestFiniteMagnitude).send(request()); XCTFail("Expected invalid deadline") }
            catch { timedOut(error) }
            let requests = await http.requests; XCTAssertTrue(requests.isEmpty)
        }
    }

    func testNonfiniteOrRegressedCompletionClockCannotQualifySuccess() async throws {
        for time in [TimeInterval.nan, .infinity, 99] {
            let http = DeadlineHTTP(), sleeper = DeadlineSleeper(), clock = DeadlineClock()
            let transport = owner(http, sleeper, clock), request = request()
            let task = Task { try await transport.send(request) }
            await http.waitUntilStarted(); await sleeper.waitUntilStarted()
            clock.set(time); await http.complete(.success(DeadlineHTTP.response))
            do { _ = try await task.value; XCTFail("Expected invalid clock") }
            catch { timedOut(error) }
        }
    }
}

private final class DeadlineClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 100
    func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
    func set(_ value: TimeInterval) { lock.lock(); defer { lock.unlock() }; time = value }
}
private actor DeadlineCompletion { private(set) var finished = false; func mark() { finished = true } }

private actor DeadlineHTTP {
    static let response = (Data("authoritative bytes".utf8), URLResponse(url: URL(string: "https://example.com/control/v1/matches/game/commands")!, mimeType: "application/json", expectedContentLength: 19, textEncodingName: "utf-8"))
    private var reply: CheckedContinuation<(Data, URLResponse), Error>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var cancelWaiter: CheckedContinuation<Void, Never>?
    private var cancelled = false
    private(set) var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                requests.append(request); reply = continuation
                startWaiter?.resume(); startWaiter = nil
            }
        } onCancel: { Task { await self.recordCancellation() } }
    }
    private func recordCancellation() {
        cancelled = true; cancelWaiter?.resume(); cancelWaiter = nil
        // Deliberately leave HTTP suspended until complete() joins its work.
    }
    func waitUntilStarted() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func waitUntilCancelled() async {
        if cancelled { return }
        await withCheckedContinuation { cancelWaiter = $0 }
    }
    func complete(_ result: Result<(Data, URLResponse), Error>) { reply?.resume(with: result); reply = nil }
}

private actor DeadlineSleeper {
    private var id = 0
    private var continuation: CheckedContinuation<Void, Error>?
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var delays: [TimeInterval] = []
    private(set) var cancelled = false
    var activeCount: Int { continuation == nil ? 0 : 1 }
    func sleep(_ delay: TimeInterval) async throws {
        id += 1; let current = id
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation; delays.append(delay)
                let ready = waiters.filter { $0.0 <= delays.count }; waiters.removeAll { $0.0 <= delays.count }
                for (_, waiter) in ready { waiter.resume() }
            }
        } onCancel: { Task { await self.cancel(current) } }
    }
    private func cancel(_ current: Int) {
        cancelled = true
        guard current == id else { return }
        continuation?.resume(throwing: CancellationError()); continuation = nil
    }
    func wake() { continuation?.resume(); continuation = nil }
    func waitUntilStarted(count: Int = 1) async {
        if delays.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}
