import AVFoundation
import Foundation
import ScorebugCore
import ScorebugMedia
import XCTest

@MainActor final class CaptureStreamingModelTests: XCTestCase {
    func testOfflineRecordDoesNotCallAPI() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server, saved: nil)
        let context = captureContext()
        model.captureChanged(context)
        await model.pollControl()
        model.captureChanged(nil)
        await model.pollControl()
        let count = await server.requestCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(model.localState, .idle)
    }

    func testStreamingStartAndStopLeaveLocalCaptureActive() async throws {
        let server = CaptureTestServer()
        let publisher = CaptureTestPublisher()
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        let context = captureContext()
        model.captureChanged(context)
        await model.startStreaming()
        XCTAssertEqual(model.localState, .publishing)
        let isPublishing = await publisher.isPublishing
        XCTAssertTrue(isPublishing)
        await model.stopStreaming()
        let stopped = await publisher.isPublishing
        XCTAssertFalse(stopped)
        XCTAssertEqual(model.activeRecordingID, context.id)
        XCTAssertEqual(model.localState, .idle)
        let operations = await server.operations
        XCTAssertEqual(operations, ["start", "stop"])
    }

    func testStopDuringPublishAccessCannotStartLatePublisher() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        await server.setPublishGate(gate)
        let publisher = CaptureTestPublisher()
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        let starting = Task { await model.startStreaming() }
        await gate.waitUntilEntered()
        model.captureChanged(nil)
        await gate.release()
        await starting.value
        await model.pollControl()
        let stopped = await publisher.isPublishing
        XCTAssertFalse(stopped)
        let starts = await publisher.startCount
        XCTAssertEqual(starts, 0)
        XCTAssertNil(model.activeRecordingID)
    }

    func testNetworkFailureDoesNotClearLocalRecording() async throws {
        let server = CaptureTestServer()
        await server.setOffline(true)
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        XCTAssertEqual(model.activeRecordingID, "recording-1")
        XCTAssertEqual(model.localState, .failed)
        XCTAssertNotNil(model.message)
    }

    func testRelaunchReplacesLiveReportWithHigherSequenceInterruptedReport() async throws {
        let server = CaptureTestServer()
        let saved = captureSetup()
        let storage = CaptureMemoryStorage(saved)
        let model = makeModel(server: server, storage: storage)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        let before = try XCTUnwrap(storage.value?.reports.first)
        let relaunched = makeModel(server: server, storage: storage)
        await relaunched.restore()
        XCTAssertNil(relaunched.activeRecordingID)
        let terminal = try XCTUnwrap(storage.value?.reports.first)
        XCTAssertEqual(terminal.report.status, .interrupted)
        XCTAssertGreaterThan(terminal.report.sequence, before.report.sequence)
        XCTAssertEqual(terminal.report.startedAt, before.report.startedAt)
        await relaunched.pollControl()
        let lastStatus = await server.reports.last?.status
        XCTAssertEqual(lastStatus, .interrupted)
        await model.stopStreaming()
    }

    func testStorageFailureCanRetryRestoreWithoutDiscardingSetup() async throws {
        let server = CaptureTestServer()
        let storage = CaptureMemoryStorage(captureSetup())
        storage.fails = true
        let model = makeModel(server: server, storage: storage)
        await model.restore()
        XCTAssertTrue(model.needsStorageRetry)
        storage.fails = false
        await model.pollControl()
        XCTAssertEqual(model.connectedGameID, "game-1")
        XCTAssertFalse(model.needsStorageRetry)
    }

    func testWorkerDecodedVideoAgeStoredAndExpiresWithoutAnotherRequest() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        await server.setStatusOverride(workerAgeResponse())
        await model.pollControl()
        let evidence = try XCTUnwrap(model.workerDecodedVideoFreshness)
        XCTAssertEqual(evidence.gameId, "game-1")
        XCTAssertEqual(evidence.generation, 1)
        XCTAssertEqual(evidence.workerId, "worker-1")
        XCTAssertEqual(evidence.attempt, 2)
        XCTAssertEqual(evidence.completed.sequence, 7)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(evidence.ageUpperBound()), .milliseconds(550))
        XCTAssertEqual(model.workerState, .producingOutput)
        let requestsBefore = await server.requestCount
        model.pollLocalHealth(at: ContinuousClock.now + .seconds(5))
        XCTAssertNil(model.workerDecodedVideoFreshness)
        XCTAssertEqual(model.workerState, .stale)
        XCTAssertEqual(model.localState, .publishing)
        let requestsAfter = await server.requestCount
        XCTAssertEqual(requestsAfter, requestsBefore)
        await model.stopStreaming()
    }

    func testLegacyWorkerReplyClearsPreviouslyStoredAgeWithoutChangingProcessHealth() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        await server.setStatusOverride(workerAgeResponse())
        await model.pollControl()
        XCTAssertNotNil(model.workerDecodedVideoFreshness)
        await server.setStatusOverride(workerAgeResponse(bound: nil))
        await model.pollControl()
        XCTAssertNil(model.workerDecodedVideoFreshness)
        XCTAssertEqual(model.workerState, .producingOutput)
        await server.setStatusOverride(workerAgeResponse())
        await model.pollControl()
        XCTAssertNotNil(model.workerDecodedVideoFreshness)
        await model.stopStreaming()
        XCTAssertNil(model.workerDecodedVideoFreshness)
    }

    func testWorkerScopeMismatchClearsPreviouslyStoredAge() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        for field in ["game", "generation", "worker"] {
            await server.setStatusOverride(workerAgeResponse())
            await model.pollControl()
            XCTAssertNotNil(model.workerDecodedVideoFreshness)
            var mismatch = workerAgeResponse()
            switch field {
            case "game": mismatch.status.gameId = "other"
            case "generation": mismatch.status.generation = 2
            default: mismatch.status.workerId = "other"
            }
            await server.setStatusOverride(mismatch)
            await model.pollControl()
            XCTAssertNil(model.workerDecodedVideoFreshness)
            XCTAssertEqual(model.workerState, .unknown)
        }
        await model.stopStreaming()
    }

    func testLateWorkerFailureAfterStopIsIgnoredAndRestartWaitsForControlCompletion() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        var publishers: [CaptureTestPublisher] = []
        let model = makeModel(server: server, publisherFactory: { _, _ in
            let publisher = CaptureTestPublisher(); publishers.append(publisher); return publisher
        })
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        await server.setStatusGate(gate)
        await server.setStatusFailure(true)
        let polling = Task { await model.pollControl() }
        await gate.waitUntilEntered()
        await model.stopStreaming()
        let messageAfterStop = model.message
        await model.startStreaming()
        XCTAssertEqual(publishers.count, 1, "A pending control request blocks replacement startup")
        XCTAssertEqual(model.localState, .idle)
        await gate.release()
        await polling.value
        XCTAssertEqual(model.localState, .idle)
        XCTAssertEqual(model.message, messageAfterStop, "An obsolete worker failure must not overwrite current status")
        XCTAssertEqual(model.workerState, .unknown)
        await server.setStatusFailure(false)
        await server.setStatusGate(nil)
        await model.startStreaming()
        XCTAssertEqual(publishers.count, 2)
        XCTAssertEqual(model.localState, .publishing)
        await model.pollControl()
        XCTAssertEqual(model.localState, .publishing)
        let replacementPublishing = await publishers.last?.isPublishing
        XCTAssertEqual(replacementPublishing, true)
        let operations = await server.operations
        XCTAssertEqual(operations, ["start"], "Obsolete failure must not trigger a stop of the replacement")
        await model.stopStreaming()
    }

    func testWorkerReplyAfterLocalStopCannotReappearAsCurrent() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        await server.setStatusOverride(workerAgeResponse())
        await model.pollControl()
        XCTAssertNotNil(model.workerDecodedVideoFreshness)
        await server.setStatusGate(gate)
        let polling = Task { await model.pollControl() }
        await gate.waitUntilEntered()
        model.captureChanged(nil)
        XCTAssertNil(model.workerDecodedVideoFreshness)
        await gate.release()
        await polling.value
        XCTAssertEqual(model.workerState, .unknown)
        XCTAssertNil(model.workerDecodedVideoFreshness)
    }

    func testWorkerObservationExpiresIndependentlyOfControlRequests() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        await model.pollControl()
        XCTAssertEqual(model.workerState, .stale)
        await model.stopStreaming()
    }

    func testLostStartReplyRecoversReceiptAndStopsOnlyOwnedRecording() async throws {
        let server = CaptureTestServer()
        await server.setDropReply()
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        XCTAssertNotNil(model.commandState?.pending)
        model.captureChanged(nil)
        await model.pollControl()
        XCTAssertNil(model.commandState?.pending)
        let operations = await server.operations
        XCTAssertEqual(operations, ["start", "stop"])
    }

    func testStopNeverStopsAnotherCaptureSelection() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        await server.selectAnotherCapture()
        await model.stopStreaming()
        let operations = await server.operations
        XCTAssertEqual(operations, ["start"])
    }

    func testStopDuringPublisherStartupIsTerminal() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        let publisher = CaptureTestPublisher(gate: gate)
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        let starting = Task { await model.startStreaming() }
        await gate.waitUntilEntered()
        model.captureChanged(nil)
        await gate.release()
        await starting.value
        let active = await publisher.isPublishing
        XCTAssertFalse(active)
        XCTAssertEqual(model.localState, .idle)
    }

    func testStopDuringCaptureJoinPreventsAnyBroadcastOrPublisherStart() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        await server.setJoinGate(gate)
        var saved = captureSetup(); saved.credential = nil
        let publisher = CaptureTestPublisher()
        let model = makeModel(server: server, saved: saved, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        let starting = Task { await model.startStreaming() }
        await gate.waitUntilEntered()
        model.captureChanged(nil)
        await gate.release()
        await starting.value
        let operations = await server.operations
        let starts = await publisher.startCount
        XCTAssertTrue(operations.isEmpty)
        XCTAssertEqual(starts, 0)
        XCTAssertNil(model.activeRecordingID)
    }

    func testBroadcastStorageFailureIsVisibleAndDoesNotPOST() async throws {
        let server = CaptureTestServer()
        let pending = CaptureMemoryPending()
        let model = CaptureStreamingModel(storage: CaptureMemoryStorage(captureSetup()), pendingStore: pending,
            clientFactory: { endpoint in MatchHTTPClient(endpoint: endpoint, transport: { try await server.respond($0) }) },
            publisherFactory: { _, _ in CaptureTestPublisher() })
        await model.restore()
        pending.fails = true
        model.captureChanged(captureContext())
        await model.startStreaming()
        XCTAssertTrue(model.needsStorageRetry)
        XCTAssertFalse(model.canChangeSetup)
        let operations = await server.operations
        XCTAssertTrue(operations.isEmpty)
        pending.fails = false
        await model.pollControl()
        XCTAssertFalse(model.needsStorageRetry)
    }

    func testSetupPersistsDeviceIdentityBeforeFailedJoin() async throws {
        let server = CaptureTestServer()
        await server.setOffline(true)
        let storage = CaptureMemoryStorage(nil)
        let model = makeModel(server: server, storage: storage)
        await model.restore()
        model.installationToken = "token"
        await model.connect()
        let first = try XCTUnwrap(storage.value?.deviceId)
        XCTAssertNotNil(UUID(uuidString: first))
        let next = makeModel(server: server, storage: storage)
        await next.restore()
        await next.connect()
        XCTAssertEqual(storage.value?.deviceId, first)
    }

    func testStopStreamingDoesNotReplayAnUncommittedStartWhileArchiveContinues() async throws {
        let server = CaptureTestServer()
        await server.setFailBeforeCommand()
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        XCTAssertNotNil(model.commandState?.pending)
        await model.stopStreaming()
        XCTAssertEqual(model.activeRecordingID, "recording-1")
        let operations = await server.operations
        XCTAssertTrue(operations.isEmpty)
        XCTAssertNotNil(model.commandState?.pending)
    }

    func testSecondRelaunchRetainsStopOwnershipAfterTerminalReportAcknowledgment() async throws {
        let server = CaptureTestServer()
        let storage = CaptureMemoryStorage(captureSetup())
        let model = makeModel(server: server, storage: storage)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        model.captureChanged(nil)
        await server.setFailMedia(true)
        await model.stopStreaming()
        XCTAssertTrue(storage.value?.reports.isEmpty == true, "Terminal report was acknowledged before media lookup failed")
        let relaunched = makeModel(server: server, storage: storage)
        await relaunched.restore()
        await server.setFailMedia(false)
        await relaunched.pollControl()
        let operations = await server.operations
        XCTAssertEqual(operations, ["start", "stop"])
    }

    func testSetupSaveFailureCannotBeBypassedByRetryingSameFields() async throws {
        let server = CaptureTestServer()
        let storage = CaptureMemoryStorage(nil)
        let model = makeModel(server: server, storage: storage)
        await model.restore()
        model.installationToken = "test-token"
        storage.fails = true
        await model.connect()
        await model.connect()
        let requestsBeforeSave = await server.requestCount
        XCTAssertEqual(requestsBeforeSave, 0, "No join may use an identity that has not been saved")
        storage.fails = false
        await model.connect()
        XCTAssertEqual(model.connectedGameID, "game-1")
    }

    func testBlockedPublisherStopPreventsOverlappingRestart() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        let publisher = CaptureTestPublisher(stopGate: gate)
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        let stopping = Task { await model.stopStreaming() }
        await gate.waitUntilEntered()
        XCTAssertFalse(model.canStart)
        await model.startStreaming()
        let starts = await publisher.startCount
        XCTAssertEqual(starts, 1)
        await gate.release()
        await stopping.value
        XCTAssertTrue(model.canStart)
    }

    func testIndependentPollDefersOwnedStopUntilPublisherFinishCompletes() async throws {
        let trace = CaptureStopOrderTrace()
        let server = CaptureTestServer(stopOrderTrace: trace)
        let finishGate = FilmTestGate()
        let publisher = CaptureTestPublisher(stopGate: finishGate, stopOrderTrace: trace)
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        XCTAssertEqual(model.localState, .publishing)

        let stopping = Task { await model.stopStreaming() }
        let finishEntered = await finishGate.waitUntilEntered(timeout: .seconds(2))
        XCTAssertTrue(finishEntered, "Publisher finish must be pending before the independent poll")
        if finishEntered {
            await model.pollControl()
            let operations = await server.operations
            let desired = await server.broadcast.desired
            XCTAssertEqual(operations, ["start"], "Control stop must wait for publisher finish: \(trace.events)")
            XCTAssertEqual(desired, .running)
            XCTAssertEqual(trace.events, ["publisher.finish.entered"])
        }
        await finishGate.release()
        await stopping.value
        let operations = await server.operations
        let desired = await server.broadcast.desired
        XCTAssertEqual(operations, ["start", "stop"])
        XCTAssertEqual(desired, .stopped)
        XCTAssertEqual(trace.events, ["publisher.finish.entered", "publisher.finish.completed", "server.stop"])
        XCTAssertEqual(model.activeRecordingID, "recording-1")
    }

    func testInFlightRecoveryDefersOwnedStopUntilPublisherFinishCompletes() async throws {
        let trace = CaptureStopOrderTrace()
        let server = CaptureTestServer(stopOrderTrace: trace)
        let recoveryGate = FilmTestGate(), finishGate = FilmTestGate()
        let publisher = CaptureTestPublisher(stopGate: finishGate, stopOrderTrace: trace)
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        XCTAssertEqual(model.localState, .publishing)

        await server.setSnapshotGate(recoveryGate)
        let polling = Task { await model.pollControl() }
        let recoveryEntered = await recoveryGate.waitUntilEntered(timeout: .seconds(2))
        XCTAssertTrue(recoveryEntered, "The poll must already be suspended in snapshot recovery")
        let stopping = Task { await model.stopStreaming() }
        let finishEntered = await finishGate.waitUntilEntered(timeout: .seconds(2))
        XCTAssertTrue(finishEntered, "Publisher finish must be pending before recovery resumes")
        await recoveryGate.release()
        await polling.value
        if recoveryEntered && finishEntered {
            let operations = await server.operations
            let desired = await server.broadcast.desired
            XCTAssertEqual(operations, ["start"], "Resumed recovery must wait for publisher finish: \(trace.events)")
            XCTAssertEqual(desired, .running)
            XCTAssertEqual(trace.events, ["publisher.finish.entered"])
        }
        await finishGate.release()
        await stopping.value
        let operations = await server.operations
        let desired = await server.broadcast.desired
        XCTAssertEqual(operations, ["start", "stop"])
        XCTAssertEqual(desired, .stopped)
        XCTAssertEqual(trace.events, ["publisher.finish.entered", "publisher.finish.completed", "server.stop"])
        XCTAssertEqual(model.activeRecordingID, "recording-1")
    }

    func testCaptureEndDefersTerminalControlUntilPublisherFinishCompletes() async throws {
        let trace = CaptureStopOrderTrace()
        let server = CaptureTestServer(stopOrderTrace: trace)
        let finishGate = FilmTestGate()
        let publisher = CaptureTestPublisher(stopGate: finishGate, stopOrderTrace: trace)
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        XCTAssertEqual(model.localState, .publishing)

        model.captureChanged(nil)
        let finishEntered = await finishGate.waitUntilEntered(timeout: .seconds(2))
        XCTAssertTrue(finishEntered)
        if finishEntered {
            await model.pollControl()
            let operations = await server.operations
            let desired = await server.broadcast.desired
            let statuses = await server.reports.map(\.status)
            XCTAssertEqual(operations, ["start"], "Capture end must wait for publisher finish: \(trace.events)")
            XCTAssertEqual(desired, .running)
            XCTAssertEqual(statuses, [.recording], "The capture terminal report should remain queued while finish is pending")
        }
        await finishGate.release()
        await model.stopStreaming()
        await model.pollControl()
        let operations = await server.operations
        let statuses = await server.reports.map(\.status)
        XCTAssertEqual(operations, ["start", "stop"], "Later polls must not duplicate the owned stop")
        XCTAssertEqual(statuses, [.recording, .stopped])
        XCTAssertEqual(trace.events, ["publisher.finish.entered", "publisher.finish.completed", "server.stop"])
        XCTAssertNil(model.activeRecordingID)
    }

    func testCaptureFailureReportsInterruptedAfterArchiveOutcome() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = CaptureTestServer()
        let storage = CaptureMemoryStorage(captureSetup())
        let streaming = makeModel(server: server, storage: storage)
        await streaming.restore()
        let source = FilmTestSource()
        let film = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { source }, sinkFactory: testArchiveSink)
        film.onCaptureChanged = { streaming.captureChanged($0, terminalStatus: nil) }
        film.onCaptureFinished = { streaming.captureFinished($0, interrupted: $1) }
        await film.start()
        source.interrupt()
        await film.pollHealth()
        XCTAssertNil(film.currentCapture)
        XCTAssertEqual(storage.value?.reports.last?.report.status, .interrupted)
        XCTAssertEqual(storage.value?.reports.last?.report.sequence, 2)
    }

    func testRejectedStopKeepsOwnershipAcrossRelaunch() async throws {
        let server = CaptureTestServer()
        let storage = CaptureMemoryStorage(captureSetup())
        let model = makeModel(server: server, storage: storage)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        model.captureChanged(nil)
        await server.setRejectStop()
        await model.stopStreaming()
        XCTAssertEqual(storage.value?.stopRecordingIDs, ["recording-1"])
        let relaunched = makeModel(server: server, storage: storage)
        await relaunched.restore()
        await relaunched.pollControl()
        let operations = await server.operations
        XCTAssertEqual(operations, ["start", "stop"])
        XCTAssertTrue(storage.value?.stopRecordingIDs?.isEmpty == true)
    }

    func testHealthFailureTeardownBlocksRestartUntilOldPublisherStops() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        let publisher = CaptureTestPublisher(stopGate: gate)
        let model = makeModel(server: server, publisher: publisher)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        await publisher.failHealth()
        await gate.waitUntilEntered()
        model.pollLocalHealth()
        XCTAssertEqual(model.localState, .failed)
        XCTAssertFalse(model.canStart)
        await model.startStreaming()
        let starts = await publisher.startCount
        XCTAssertEqual(starts, 1)
        await gate.release()
        await model.stopStreaming()
        XCTAssertTrue(model.canStart)
    }

    func testCaptureCallbacksAreObservedDuringPublisherStartupBeforeReadiness() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        let publisher = CaptureTestPublisher(gate: gate)
        var owners: [VideoFrameObservationOwner] = []
        let model = makeModel(server: server, publisherFactory: { _, owner in
            owners.append(try XCTUnwrap(owner)); return publisher
        })
        await model.restore()
        let source = FilmTestSource()
        let film = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { source }, sinkFactory: testArchiveSink)
        film.onCaptureChanged = { model.captureChanged($0) }
        await film.start()
        let context = try XCTUnwrap(film.currentCapture)
        source.send(try streamingVideo(0)) // Before publish access: outside the measured interval.
        let starting = Task { await model.startStreaming() }
        await gate.waitUntilEntered()
        let owner = try XCTUnwrap(owners.first)
        source.send(try streamingVideo(1))
        source.send(try streamingVideo(2))
        model.pollLocalHealth()
        let snapshot = try XCTUnwrap(model.videoObservation)
        XCTAssertEqual(snapshot.scope.recordingID, context.id)
        XCTAssertEqual(snapshot.scope.matchID, "game-1")
        XCTAssertEqual(snapshot.scope.broadcastGeneration, 1)
        XCTAssertEqual(snapshot.scope.appliedProfileRevision, 1)
        XCTAssertEqual(snapshot.scope, owner.snapshot.scope)
        XCTAssertEqual(model.ingressObservation?.scope, snapshot.scope)
        XCTAssertEqual(model.ingressObservation?.monotonicAnchor, snapshot.monotonicAnchor)
        XCTAssertEqual(model.ingressObservation?.phase, .startup)
        XCTAssertTrue(model.ingressObservation?.totalDispositions.isEmpty == true)
        XCTAssertEqual(snapshot.current.captureVideo.callbackCount, 2)
        XCTAssertEqual(snapshot.current.encodedVideo.callbackCount, 0)
        XCTAssertEqual(snapshot.current.captureVideo.firstSourcePTS, CMTime(value: 1, timescale: 30))
        XCTAssertFalse(snapshot.isClosed)
        XCTAssertEqual(model.localState, .starting)
        let appends = await publisher.appendCount
        XCTAssertEqual(appends, 0)
        XCTAssertEqual(model.sentSamples, 0)
        await gate.release()
        await starting.value
        XCTAssertEqual(model.localState, .publishing)
        source.send(try streamingVideo(3))
        await publisher.waitForAppends(1)
        model.pollLocalHealth()
        XCTAssertEqual(model.videoObservation?.current.captureVideo.callbackCount, 3)
        XCTAssertEqual(model.ingressObservation?.phase, .admitting)
        XCTAssertEqual(model.ingressObservation?.totalDispositions[.admitted]?[.video]?.count, 1)
        XCTAssertEqual(model.ingressObservation?.totalDispositions[.dequeued]?[.video]?.count, 1)
        XCTAssertEqual(model.ingressObservation?.totalDispositions[.admitted]?[.video]?.firstSourcePTS, CMTime(value: 3, timescale: 30))
        await model.stopStreaming()
        XCTAssertEqual(model.ingressObservation?.isClosed, true)
        XCTAssertEqual(film.state, .recording)
        await film.stop()
        XCTAssertEqual(film.recordings.first?.status, .completed)
    }

    func testCaptureStopDuringStartupDetachesImmediatelyAndClosesOnlyAfterJoinedStop() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = CaptureTestServer()
        let startupGate = FilmTestGate(), stopGate = FilmTestGate()
        let publisher = CaptureTestPublisher(gate: startupGate, stopGate: stopGate)
        var capturedOwner: VideoFrameObservationOwner?
        let model = makeModel(server: server, publisherFactory: { _, owner in capturedOwner = owner; return publisher })
        await model.restore()
        let source = FilmTestSource()
        let film = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { source }, sinkFactory: testArchiveSink)
        film.onCaptureChanged = { model.captureChanged($0) }
        await film.start()
        let starting = Task { await model.startStreaming() }
        await startupGate.waitUntilEntered()
        let owner = try XCTUnwrap(capturedOwner)
        source.send(try streamingVideo(1))
        // The same synchronous callback FilmModel uses must detach before archive shutdown.
        model.captureChanged(nil)
        source.send(try streamingVideo(2))
        XCTAssertEqual(owner.snapshot.current.captureVideo.callbackCount, 1)
        XCTAssertFalse(owner.snapshot.isClosed)
        await stopGate.waitUntilEntered()
        owner.observe(.encodedVideo, sourcePTS: CMTime(value: 1, timescale: 30))
        await startupGate.release()
        XCTAssertFalse(owner.snapshot.isClosed)
        await stopGate.release()
        await starting.value
        await model.stopStreaming() // Joins the teardown even after the action completed.
        XCTAssertEqual(model.localState, .idle)
        XCTAssertNil(model.activeRecordingID)
        XCTAssertEqual(model.videoObservation?.isClosed, true)
        XCTAssertEqual(model.videoObservation?.current.captureVideo.callbackCount, 1)
        XCTAssertEqual(model.videoObservation?.current.encodedVideo.callbackCount, 1)
        let ready = await publisher.isPublishing
        XCTAssertFalse(ready)
        XCTAssertFalse(owner.observe(.encodedVideo, sourcePTS: CMTime(value: 2, timescale: 30)))
        await film.stop()
        XCTAssertEqual(film.recordings.first?.status, .completed)
    }

    func testGatedEncoderStopKeepsOldOwnerOpenAndRestartUsesFreshScope() async throws {
        let server = CaptureTestServer()
        let gate = FilmTestGate()
        let first = CaptureTestPublisher(stopGate: gate), second = CaptureTestPublisher()
        var owners: [VideoFrameObservationOwner] = []
        let model = makeModel(server: server, publisherFactory: { _, owner in
            owners.append(try XCTUnwrap(owner)); return owners.count == 1 ? first : second
        })
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        let old = try XCTUnwrap(owners.first)
        XCTAssertEqual(model.ingressObservation?.scope, old.snapshot.scope)
        let stopping = Task { await model.stopStreaming() }
        await gate.waitUntilEntered()
        let closedIngress = model.ingressObservation
        XCTAssertEqual(closedIngress?.isClosed, true, "Ingress closes before the encoder drains")
        XCTAssertFalse(model.canStart)
        await model.startStreaming()
        XCTAssertEqual(owners.count, 1)
        XCTAssertFalse(old.snapshot.isClosed)
        XCTAssertTrue(old.observe(.encodedVideo, sourcePTS: .zero))
        await gate.release()
        await stopping.value
        let final = try XCTUnwrap(model.videoObservation)
        XCTAssertTrue(final.isClosed)
        XCTAssertEqual(model.ingressObservation?.current.monotonicEnd, closedIngress?.current.monotonicEnd)
        XCTAssertEqual(final.scope, old.snapshot.scope)
        XCTAssertEqual(final.current.encodedVideo.callbackCount, 1)
        XCTAssertFalse(old.observe(.encodedVideo, sourcePTS: CMTime(value: 1, timescale: 30)))
        XCTAssertTrue(model.canStart)
        await model.startStreaming()
        XCTAssertEqual(owners.count, 2)
        let fresh = owners[1]
        XCTAssertFalse(fresh === old)
        XCTAssertNotEqual(fresh.snapshot.scope.publishingAttemptID, final.scope.publishingAttemptID)
        XCTAssertGreaterThan(fresh.snapshot.scope.broadcastGeneration, final.scope.broadcastGeneration)
        XCTAssertEqual(model.videoObservation?.current.encodedVideo.callbackCount, 0)
        XCTAssertFalse(old.observe(.encodedVideo, sourcePTS: CMTime(value: 2, timescale: 30)))
        old.close()
        model.pollLocalHealth()
        XCTAssertEqual(model.videoObservation?.scope, fresh.snapshot.scope)
        XCTAssertEqual(model.ingressObservation?.scope, fresh.snapshot.scope)
        XCTAssertEqual(model.ingressObservation?.isClosed, false)
        XCTAssertTrue(model.ingressObservation?.totalDispositions.isEmpty == true)
        XCTAssertEqual(model.videoObservation?.current.encodedVideo.callbackCount, 0)
        XCTAssertEqual(model.videoObservation?.isClosed, false)
        await model.stopStreaming()
        XCTAssertTrue(fresh.snapshot.isClosed)
    }

    func testClosedCaptureTapRejectsStartupAndStillClosesCreatedOwner() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let film = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { FilmTestSource() }, sinkFactory: testArchiveSink)
        await film.start()
        let closedContext = try XCTUnwrap(film.currentCapture)
        await film.stop()
        let server = CaptureTestServer()
        let publisher = CaptureTestPublisher()
        var owner: VideoFrameObservationOwner?
        let model = makeModel(server: server, publisherFactory: { _, observations in owner = observations; return publisher })
        await model.restore()
        model.captureChanged(closedContext)
        await model.startStreaming()
        await model.stopStreaming()
        XCTAssertEqual(model.videoObservation?.isClosed, true)
        XCTAssertEqual(owner?.snapshot.isClosed, true)
        let starts = await publisher.startCount
        XCTAssertEqual(starts, 0)
        let stopped = await publisher.terminated
        XCTAssertTrue(stopped)
    }

    func testThrowingPublisherFactoryClosesOrphanedOwner() async throws {
        let server = CaptureTestServer()
        var owner: VideoFrameObservationOwner?
        let model = makeModel(server: server, publisherFactory: { _, observations in
            owner = observations; throw URLError(.cannotConnectToHost)
        })
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        XCTAssertEqual(model.localState, .failed)
        XCTAssertEqual(model.activeRecordingID, "recording-1")
        XCTAssertFalse(model.needsStorageRetry)
        XCTAssertEqual(owner?.snapshot.isClosed, true)
        XCTAssertEqual(model.videoObservation?.isClosed, true)
        XCTAssertEqual(model.videoObservation?.scope, owner?.snapshot.scope)
        await model.stopStreaming()
    }

    func testUnavailableObservationDoesNotFailPublisherArchiveOrStorage() async throws {
        let root = testRecordingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = CaptureTestServer()
        let publisher = CaptureTestPublisher()
        var receivedNil = false
        let model = makeModel(server: server, publisherFactory: { _, owner in
            receivedNil = owner == nil; return publisher
        }, observationFactory: { _ in throw VideoFrameObservationError.invalidConfiguration })
        await model.restore()
        let source = FilmTestSource()
        let film = FilmModel(library: RecordingLibrary(rootDirectory: root), sourceFactory: { source }, sinkFactory: testArchiveSink)
        film.onCaptureChanged = { model.captureChanged($0) }
        await film.start()
        await model.startStreaming()
        XCTAssertTrue(receivedNil)
        XCTAssertEqual(model.localState, .publishing)
        source.send(try streamingVideo(1))
        await publisher.waitForAppends(1)
        model.pollLocalHealth()
        XCTAssertNil(model.videoObservation)
        XCTAssertFalse(model.needsStorageRetry)
        XCTAssertNil(model.ingressObservation)
        await model.stopStreaming()
        XCTAssertNil(model.videoObservation)
        XCTAssertEqual(film.state, .recording)
        await film.stop()
        XCTAssertEqual(film.recordings.first?.status, .completed)
    }

    func testAttemptFailureBeforePublishAccessClearsPreviousDiagnostics() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server)
        await model.restore()
        model.captureChanged(captureContext())
        await model.startStreaming()
        await model.stopStreaming()
        XCTAssertEqual(model.videoObservation?.isClosed, true)
        await server.setOffline(true)
        await model.startStreaming()
        XCTAssertEqual(model.localState, .failed)
        XCTAssertNil(model.videoObservation)
        XCTAssertNil(model.ingressObservation)
        XCTAssertEqual(model.activeRecordingID, "recording-1")
        XCTAssertFalse(model.needsStorageRetry)
    }

    func testPollRecordsActualHelperReturnAndClearsProofOnLatestUnusableOrExpiry() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server)
        model.workerReportAgeProofsEnabled = true
        await model.restore(); model.captureChanged(captureContext()); await model.startStreaming()
        let scope = try XCTUnwrap(model.videoObservation?.scope)
        for invalid in ["nil", "invalid", "expired"] {
            await server.setStatusOverride(workerAgeResponse())
            await model.pollControl()
            let proof = try XCTUnwrap(model.workerReportAgeProofHistory.proofs.first)
            XCTAssertEqual(proof.recordingID, "recording-1")
            XCTAssertEqual(proof.publishingAttemptID, scope.publishingAttemptID.uuidString)
            XCTAssertEqual(proof.gameId, "game-1")
            XCTAssertEqual(proof.generation, 1)
            XCTAssertEqual(proof.workerId, "worker-1")
            XCTAssertEqual(proof.attempt, 2)
            XCTAssertEqual(proof.completed.sequence, 7)
            XCTAssertEqual(proof.decodedVideoAgeUpperBoundMs, 550)
            XCTAssertNotEqual(proof.requestDuration.attoseconds, "0")
            if invalid == "expired" { model.pollLocalHealth(at: ContinuousClock.now + .seconds(5)) }
            else {
                var latest = workerAgeResponse(bound: invalid == "nil" ? nil : 550)
                if invalid == "invalid" { latest.status.observation?.decodedVideo?.invalidReason = .numeric }
                await server.setStatusOverride(latest); await model.pollControl()
            }
            XCTAssertTrue(model.workerReportAgeProofHistory.proofs.isEmpty)
        }
        await model.stopStreaming()
    }

    func testProofRecordingRequiresFlagAndActiveAttemptAndClearsAcrossStopRestartAndRemoteMismatch() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server, publisherFactory: { _, _ in CaptureTestPublisher() })
        await model.restore(); model.captureChanged(captureContext()); await model.startStreaming()
        await server.setStatusOverride(workerAgeResponse()); await model.pollControl()
        XCTAssertTrue(model.workerReportAgeProofHistory.proofs.isEmpty)
        model.workerReportAgeProofsEnabled = true
        await model.pollControl()
        let old = try XCTUnwrap(model.workerReportAgeProofHistory.proofs.first)
        var next = workerAgeResponse(); next.status.observation?.decodedVideo?.completed?.sequence = 8
        await server.setStatusOverride(next); await model.pollControl()
        XCTAssertEqual(model.workerReportAgeProofHistory.proofs.map { $0.completed.sequence }, [7, 8])
        var mismatch = workerAgeResponse(); mismatch.status.workerId = "other"
        await server.setStatusOverride(mismatch); await model.pollControl()
        XCTAssertTrue(model.workerReportAgeProofHistory.proofs.isEmpty)
        await server.setStatusOverride(workerAgeResponse()); await model.pollControl()
        XCTAssertEqual(model.workerReportAgeProofHistory.proofs.count, 1)
        await model.stopStreaming()
        XCTAssertTrue(model.workerReportAgeProofHistory.proofs.isEmpty)
        await model.pollControl()
        XCTAssertTrue(model.workerReportAgeProofHistory.proofs.isEmpty)
        await model.startStreaming()
        var new = workerAgeResponse(); new.status.generation = 3; new.status.observation?.generation = 3
        await server.setStatusOverride(new); await model.pollControl()
        let restarted = try XCTUnwrap(model.workerReportAgeProofHistory.proofs.first)
        XCTAssertNotEqual(old.publishingAttemptID, restarted.publishingAttemptID)
        XCTAssertEqual(restarted.generation, 3)
        model.captureChanged(nil)
        XCTAssertTrue(model.workerReportAgeProofHistory.proofs.isEmpty)
        await model.stopStreaming()
    }

    func testRecordingScopeChangeImmediatelyClearsProofAndCannotPollOldPublisherIntoNewRecording() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server)
        model.workerReportAgeProofsEnabled = true
        await model.restore(); model.captureChanged(captureContext()); await model.startStreaming()
        await server.setStatusOverride(workerAgeResponse()); await model.pollControl()
        XCTAssertEqual(model.workerReportAgeProofHistory.proofs.count, 1)
        model.captureChanged(CurrentCapture(id: "recording-2", startedAt: "2026-09-14T00:00:01Z", tap: PublishingTap()))
        XCTAssertTrue(model.workerReportAgeProofHistory.proofs.isEmpty)
        await model.pollControl()
        XCTAssertTrue(model.workerReportAgeProofHistory.proofs.isEmpty)
        await model.stopStreaming()
    }

    func testStreamAndCaptureStopExportImmutableSnapshotBeforeHistoryClear() async throws {
        for stopCapture in [false, true] {
            let server = CaptureTestServer()
            let model = makeModel(server: server)
            model.workerReportAgeProofsEnabled = true
            var exported: [WorkerReportAgeProof]?
            var closed: VideoFrameObservationSnapshot?
            model.videoObservationFixtureWriter = { snapshot, detached, proofs, ingress in
                XCTAssertTrue(snapshot.isClosed)
                XCTAssertGreaterThanOrEqual(detached, snapshot.monotonicAnchor)
                XCTAssertEqual(ingress?.scope, snapshot.scope)
                XCTAssertEqual(ingress?.isClosed, true)
                XCTAssertEqual(ingress?.phase, .closed)
                XCTAssertEqual(ingress?.currentItems, 0)
                XCTAssertEqual(ingress?.currentBytes, 0)
                XCTAssertGreaterThanOrEqual(ingress?.current.monotonicEnd ?? 0, detached)
                XCTAssertLessThanOrEqual(ingress?.current.monotonicEnd ?? .infinity, snapshot.current.monotonicEnd)
                exported = proofs; closed = snapshot
            }
            await model.restore(); model.captureChanged(captureContext()); await model.startStreaming()
            await server.setStatusOverride(workerAgeResponse()); await model.pollControl()
            let beforeStop = model.workerReportAgeProofHistory.proofs
            XCTAssertEqual(beforeStop.count, 1)
            if stopCapture { model.captureChanged(nil) }
            await model.stopStreaming()
            XCTAssertEqual(exported, beforeStop)
            XCTAssertEqual(exported?.first?.publishingAttemptID, closed?.scope.publishingAttemptID.uuidString)
            XCTAssertTrue(model.workerReportAgeProofHistory.proofs.isEmpty)
        }
    }

    func testFixtureExportIsJoinedBeforePublishingCanRestart() async throws {
        let server = CaptureTestServer()
        let model = makeModel(server: server, publisherFactory: { _, _ in CaptureTestPublisher() })
        model.workerReportAgeProofsEnabled = true
        let gate = FilmTestGate()
        var exported: [WorkerReportAgeProof] = []
        model.videoObservationFixtureWriter = { snapshot, detached, proofs, ingress in
            XCTAssertEqual(ingress?.scope, snapshot.scope)
            XCTAssertEqual(ingress?.isClosed, true)
            XCTAssertGreaterThanOrEqual(ingress?.current.monotonicEnd ?? 0, detached)
            XCTAssertLessThanOrEqual(ingress?.current.monotonicEnd ?? .infinity, snapshot.current.monotonicEnd)
            exported = proofs
            await gate.enter()
        }
        await model.restore(); model.captureChanged(captureContext()); await model.startStreaming()
        await server.setStatusOverride(workerAgeResponse()); await model.pollControl()
        let beforeStop = model.workerReportAgeProofHistory.proofs
        let stopping = Task { await model.stopStreaming() }
        await gate.waitUntilEntered()
        XCTAssertEqual(exported, beforeStop)
        XCTAssertTrue(model.workerReportAgeProofHistory.proofs.isEmpty)
        XCTAssertFalse(model.canStart)
        await model.startStreaming()
        XCTAssertEqual(model.videoObservation?.scope.publishingAttemptID.uuidString, beforeStop.first?.publishingAttemptID)
        await gate.release(); await stopping.value
        XCTAssertTrue(model.canStart)
        model.videoObservationFixtureWriter = nil
        await model.startStreaming()
        XCTAssertNotEqual(model.videoObservation?.scope.publishingAttemptID.uuidString, beforeStop.first?.publishingAttemptID)
        XCTAssertTrue(model.workerReportAgeProofHistory.proofs.isEmpty)
        XCTAssertEqual(exported, beforeStop)
        await model.stopStreaming()
    }

    private func workerAgeResponse(bound: Double? = 550) -> WorkerMediaStatusResponse {
        let window = DecodedVideoWindow(sequence: 7, durationMs: 5000, ageMs: 250, firstPTS: 0, lastPTS: 447000,
                                       freshFrames: 150, duplicateFrames: 0, reorderedFrames: 0, valid: true)
        let observation = WorkerObservation(gameId: "game-1", generation: 1, state: .producingOutput,
            reason: nil, attempt: 2, frame: 150, outTimeUs: 1000, scoreRevision: 1,
            decodedVideo: .init(completed: window, invalidReason: nil, ended: false))
        return WorkerMediaStatusResponse(status: .init(gameId: "game-1", generation: 1, workerId: "worker-1",
            state: .producingOutput, observation: observation, observedAt: "2040-01-01T00:00:00.000Z",
            expiresAt: "2040-01-01T00:00:05.000Z", decodedVideoAgeUpperBoundMs: bound), serverTime: "2040-01-01T00:00:00.000Z")
    }

    private func makeModel(server: CaptureTestServer, saved: SavedCaptureSetup? = captureSetup(),
                           storage: CaptureMemoryStorage? = nil,
                           publisher: CaptureTestPublisher = CaptureTestPublisher(),
                           publisherFactory: ((URL, VideoFrameObservationOwner?) throws -> any MediaPublisher)? = nil,
                           observationFactory: @escaping (VideoFrameObservationScope) throws -> VideoFrameObservationOwner = { try VideoFrameObservationOwner(scope: $0) }) -> CaptureStreamingModel {
        CaptureStreamingModel(storage: storage ?? CaptureMemoryStorage(saved), pendingStore: CaptureMemoryPending(),
                              clientFactory: { endpoint in MatchHTTPClient(endpoint: endpoint, transport: { try await server.respond($0) }) },
                              publisherFactory: publisherFactory ?? { _, _ in publisher }, observationFactory: observationFactory)
    }
}

func captureContext() -> CurrentCapture { CurrentCapture(id: "recording-1", startedAt: "2026-09-14T00:00:00Z", tap: PublishingTap()) }
func captureSetup() -> SavedCaptureSetup {
    SavedCaptureSetup(endpoint: "http://localhost:18787", installationToken: "test-token", deviceId: "capture-1", workerId: "worker-1", outputId: "output-1",
                      credential: MatchCredential(gameId: "game-1", deviceId: "capture-1", role: .capture, token: "capture-token"), reports: [])
}
final class CaptureMemoryStorage: CaptureSetupStorage {
    var value: SavedCaptureSetup?
    var fails = false
    init(_ value: SavedCaptureSetup?) { self.value = value }
    func load() throws -> SavedCaptureSetup? { if fails { throw URLError(.cannotWriteToFile) }; return value }
    func save(_ value: SavedCaptureSetup) throws { if fails { throw URLError(.cannotWriteToFile) }; self.value = value }
}
final class CaptureMemoryPending: PendingBroadcastStore, @unchecked Sendable {
    var value: PendingBroadcastCommand?
    var fails = false
    func load() throws -> PendingBroadcastCommand? { if fails { throw URLError(.cannotWriteToFile) }; return value }
    func save(_ value: PendingBroadcastCommand?) throws { if fails { throw URLError(.cannotWriteToFile) }; self.value = value }
}
/// A shared synchronous history observes ordering without adding suspension points.
final class CaptureStopOrderTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var history: [String] = []
    var events: [String] { lock.withLock { history } }
    func record(_ event: String) { lock.withLock { history.append(event) } }
}
actor CaptureTestPublisher: MediaPublisher {
    var isPublishing = false
    var startCount = 0
    var appendCount = 0
    var terminated = false
    let gate: FilmTestGate?
    let stopGate: FilmTestGate?
    let stopOrderTrace: CaptureStopOrderTrace?
    init(gate: FilmTestGate? = nil, stopGate: FilmTestGate? = nil, stopOrderTrace: CaptureStopOrderTrace? = nil) {
        self.gate = gate; self.stopGate = stopGate; self.stopOrderTrace = stopOrderTrace
    }
    func start() async throws {
        startCount += 1
        if let gate { await gate.enter() }
        guard !terminated else { throw CancellationError() }
        isPublishing = true
    }
    func append(_ sample: CapturedMediaSample) async throws { appendCount += 1 }
    func waitForAppends(_ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while appendCount < count, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(appendCount, count)
    }
    func failHealth() { isPublishing = false }
    func stop() async {
        guard !terminated else { return }
        terminated = true; isPublishing = false
        stopOrderTrace?.record("publisher.finish.entered")
        if let stopGate { await stopGate.enter() }
        stopOrderTrace?.record("publisher.finish.completed")
    }
}
actor CaptureTestServer {
    let stopOrderTrace: CaptureStopOrderTrace?
    init(stopOrderTrace: CaptureStopOrderTrace? = nil) { self.stopOrderTrace = stopOrderTrace }
    var snapshotGate: FilmTestGate?
    func setSnapshotGate(_ value: FilmTestGate) { snapshotGate = value }
    var requestCount = 0
    var operations: [String] = []
    var reports: [RecordingReport] = []
    var broadcast = MediaBroadcast(desired: .stopped, generation: 0, selection: nil)
    var receipts: [String: BroadcastOutcome] = [:]
    var offline = false
    var failMedia = false
    func setFailMedia(_ value: Bool) { failMedia = value }
    var publishGate: FilmTestGate?
    var statusGate: FilmTestGate?
    var statusFailure = false
    var statusOverride: WorkerMediaStatusResponse?
    func setStatusFailure(_ value: Bool) { statusFailure = value }
    func setStatusOverride(_ value: WorkerMediaStatusResponse?) { statusOverride = value }
    var joinGate: FilmTestGate?
    func setJoinGate(_ value: FilmTestGate) { joinGate = value }
    var dropReply = false
    var failBeforeCommand = false
    var rejectStop = false
    func setRejectStop() { rejectStop = true }
    func setFailBeforeCommand() { failBeforeCommand = true }
    func setDropReply() { dropReply = true }
    func setStatusGate(_ value: FilmTestGate?) { statusGate = value }
    func selectAnotherCapture() { broadcast = .init(desired: .running, generation: broadcast.generation + 1, selection: .init(workerId: "worker-1", outputId: "output-1", captureDeviceId: "another-device", recordingId: "other-recording")) }
    func setOffline(_ value: Bool) { offline = value }
    func setPublishGate(_ value: FilmTestGate) { publishGate = value }
    func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        if offline { throw URLError(.notConnectedToInternet) }
        let path = request.url!.path
        if failMedia && path.hasSuffix("/media") { throw URLError(.notConnectedToInternet) }
        let time = ISO8601DateFormatter().string(from: Date())
        let data: Data
        if path.hasSuffix("/active") {
            data = try JSONEncoder().encode(ActiveMatchResponse(snapshot: matchSnapshot(), serverTime: time))
        } else if path.hasSuffix("/join") {
            if let joinGate { await joinGate.enter() }
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            data = try JSONEncoder().encode(MatchSessionResponse(snapshot: matchSnapshot(), credential: .init(gameId: "game-1", deviceId: body["deviceId"]!, role: .capture, token: "capture-token"), serverTime: time))
        } else if path.hasSuffix("/recordings") {
            let report = try JSONDecoder().decode(RecordingReport.self, from: request.httpBody!)
            reports.append(report)
            data = try JSONEncoder().encode(RecordingReportResponse(recording: .init(gameId: "game-1", recordingId: report.recordingId, deviceId: "capture-1", startedAt: report.startedAt, updatedAt: time, status: report.status, sequence: report.sequence), serverTime: time))
        } else if path.hasSuffix("/commands") {
            if failBeforeCommand { failBeforeCommand = false; throw URLError(.networkConnectionLost) }
            let command = try JSONDecoder().decode(BroadcastCommand.self, from: request.httpBody!)
            if case .stop = command.operation, rejectStop {
                rejectStop = false
                let rejected = BroadcastOutcome(commandId: command.commandId, accepted: false, error: "generation_conflict", snapshot: snapshot())
                return (try JSONEncoder().encode(rejected), HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!)
            }
            switch command.operation {
            case .start(let selection): broadcast = .init(desired: .running, generation: broadcast.generation + 1, selection: selection); operations.append("start")
            case .stop:
                stopOrderTrace?.record("server.stop")
                broadcast = .init(desired: .stopped, generation: broadcast.generation + 1, selection: nil); operations.append("stop")
            }
            let result = BroadcastOutcome(commandId: command.commandId, accepted: true, error: nil, snapshot: snapshot())
            receipts[command.commandId] = result
            if dropReply { dropReply = false; throw URLError(.networkConnectionLost) }
            data = try JSONEncoder().encode(result)
        } else if path.contains("/commands/") {
            if let receipt = receipts[request.url!.lastPathComponent] { data = try JSONEncoder().encode(receipt) }
            else { return (Data("{\"error\":\"command_not_found\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!) }
        } else if path.hasSuffix("/publish") {
            if let publishGate { await publishGate.enter() }
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            data = try JSONSerialization.data(withJSONObject: ["gameId": "game-1", "recordingId": body["recordingId"]!, "generation": broadcast.generation, "publishUrl": "srt://localhost:19000?streamid=test", "serverTime": time])
        } else if path.hasSuffix("/status") {
            let failure = statusFailure
            let response = statusOverride ?? WorkerMediaStatusResponse(status: .init(gameId: "game-1", generation: broadcast.generation, workerId: "worker-1", state: .producingOutput, observation: nil, observedAt: time, expiresAt: time), serverTime: time)
            if let statusGate { await statusGate.enter() }
            if failure { throw URLError(.networkConnectionLost) }
            data = try JSONEncoder().encode(response)
        } else {
            // Gate one snapshot only so submit's ownership refresh remains independent.
            if let snapshotGate { self.snapshotGate = nil; await snapshotGate.enter() }
            data = try JSONEncoder().encode(MediaSnapshotResponse(snapshot: snapshot(), serverTime: time))
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func snapshot() -> MediaSnapshot { .init(gameId: "game-1", recordings: [], broadcast: broadcast) }
}

private func matchSnapshot() throws -> MatchSnapshot {
    let json = ##"{"id":"game-1","createdAt":"2026-09-14T00:00:00Z","revision":0,"teams":{"home":{"name":"Home","shortName":"HOM","color":"#112233"},"away":{"name":"Away","shortName":"AWY","color":"#445566"}},"rules":{"bestOf":3,"pointsToWin":25,"decidingPointsToWin":15,"winBy":2,"pointCap":null},"score":{"home":0,"away":0,"set":1,"homeSets":0,"awaySets":0},"completedSets":[],"status":"active","endReason":null,"canUndo":false,"scorer":{"deviceId":"scorer-1","epoch":1},"broadcast":{"desired":"stopped","generation":0}}"##
    return try JSONDecoder().decode(MatchSnapshot.self, from: Data(json.utf8))
}

private func streamingVideo(_ frame: Int64) throws -> CapturedMediaSample {
    var pixel: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
    let buffer = try XCTUnwrap(pixel)
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
        imageBuffer: buffer, formatDescriptionOut: &format), noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: CMTime(value: frame, timescale: 30), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
        imageBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
        sampleBufferOut: &sample), noErr)
    return try CapturedMediaSample(sampleBuffer: XCTUnwrap(sample), kind: .video)
}
