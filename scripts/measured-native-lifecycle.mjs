import assert from 'node:assert/strict';
import { fixtureFrameID } from './video-observation-qualification.mjs';

const time = (n) => assert.ok(Number.isFinite(n) && n >= 0 && n <= 1e12);
const uuid = (s) => {
  assert.match(s, /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i);
  return s.toLowerCase();
};
const sameID = (a, b) => assert.equal(uuid(a), uuid(b));
const normalizeRate = (r) => ({
  acceptedAt: r.acceptedAt,
  bitRate: r.bitRate,
  configurationID: r.configurationID,
  encoderSessionID: r.encoderSessionID,
  generation: r.publishingGeneration,
  lastSubmittedPTS: r.lastSubmittedSourcePTS,
});

/** Startup and native application correspondence, not policy or capacity permission.
 * profileQualification comes from the complete measured native-frame validator.
 * The invalid aggregate fixed-format proof remains unchanged and is never qualified.
 */
export function qualifyMeasuredNativeLifecycle({
  lifecycle: audit,
  quality,
  format,
  snapshot,
  startupFormat: fixed,
  profileQualification,
}) {
  assert.equal(profileQualification.sequence, 'measured240');
  assert.deepEqual(profileQualification.scope, snapshot.scope);
  assert.deepEqual(profileQualification.receipts, format.receipts);
  assert.equal(audit.formatVersion, 1);
  assert.equal(audit.isClosed, true);
  assert.equal(audit.invalid, false);
  assert.equal(audit.overflow, false);
  assert.deepEqual(audit.scope, snapshot.scope);
  assert.equal(audit.profileRequestLimit, 16);
  assert.equal(audit.bitRateRequestLimit, 48);
  assert.ok(Array.isArray(audit.profileRequests) && audit.profileRequests.length <= 16);
  assert.ok(Array.isArray(audit.bitRateRequests) && audit.bitRateRequests.length <= 48);
  time(audit.closedAt);
  time(snapshot.monotonicAnchor);
  assert.ok(audit.closedAt >= snapshot.monotonicAnchor);
  const boundedTime = (n) => {
    time(n);
    assert.ok(n >= snapshot.monotonicAnchor && n <= audit.closedAt);
  };
  assert.equal(quality.overflow, false);
  assert.ok(Array.isArray(quality.events) && quality.events.length <= 512);
  const boot = quality.events.filter((e) => e.kind === 'bootstrap');
  assert.equal(boot.length, 1);
  assert.equal(quality.events[0], boot[0]);
  const bootstrap = boot[0];
  assert.equal(bootstrap.profileID, '240p30');
  assert.equal(bootstrap.revision, '0');
  assert.equal(bootstrap.receipt.bitRate, 350000);
  const first = format.compressedFrames[0],
    encoder = format.encoderSessions[0];
  const startup = fixed.startup,
    compressed = fixed.firstCompressed,
    encoding = fixed.firstEncoding;
  assert.equal(fixed.formatVersion, 1);
  assert.equal(fixed.isClosed, true);
  assert.equal(fixed.invalid, format.phases.length > 1);
  assert.deepEqual(fixed.scope, snapshot.scope);
  assert.equal(fixed.frames, format.frames);
  assert.equal(fixed.publishingGeneration, format.publishingGeneration);
  assert.equal(fixed.profile, '240p30');
  assert.equal(fixed.width, 426);
  assert.equal(fixed.height, 240);
  assert.equal(startup.profile, '240p30');
  assert.equal(startup.width, 426);
  assert.equal(startup.height, 240);
  assert.equal(startup.publishingGeneration, format.publishingGeneration);
  for (const id of [
    startup.encoderSessionID,
    encoding.encoderSessionID,
    bootstrap.receipt.encoderSessionID,
  ])
    sameID(id, encoder.encoderSessionID);
  const firstID = fixtureFrameID(first.sourcePTS);
  for (const pts of [
    fixed.firstSourcePTS,
    startup.firstSourcePTS,
    encoding.sourcePTS,
    encoding.outputPTS,
    compressed.sourcePTS,
    encoder.firstSourcePTS,
  ])
    assert.equal(fixtureFrameID(pts), firstID);
  assert.equal(
    fixtureFrameID(fixed.lastSourcePTS),
    fixtureFrameID(format.compressedFrames.at(-1).sourcePTS),
  );
  assert.equal(encoding.configurationID, null);
  assert.equal(encoding.configuredBitRate, null);
  for (const [field, actual] of [
    ['submittedAt', encoding.submittedAt],
    ['completedAt', encoding.completedAt],
    ['observedAt', compressed.dequeuedAt],
  ]) {
    boundedTime(actual);
    assert.equal(startup[field], actual);
  }
  assert.ok(
    startup.submittedAt <= startup.completedAt && startup.completedAt <= startup.observedAt,
  );
  assert.equal(startup.completedAt, encoder.firstCompletedAt);
  time(encoder.maximumEncodeLatencySeconds);
  assert.ok(
    startup.completedAt - startup.submittedAt <= encoder.maximumEncodeLatencySeconds + 1e-6,
  );
  assert.equal(startup.observedAt, first.dequeuedAt);
  assert.equal(compressed.publishingGeneration, format.publishingGeneration);
  assert.equal(compressed.width, 426);
  assert.equal(compressed.height, 240);
  assert.equal(compressed.valid, true);
  assert.equal(compressed.wasEncoded, true);
  assert.equal(compressed.codec, 0x61766331);
  assert.equal(compressed.isSync, true);
  assert.equal(compressed.bytes, first.byteCount);
  assert.ok(startup.observedAt <= bootstrap.receipt.acceptedAt);

  const ids = new Set();
  const unique = (id) => {
    const key = uuid(id);
    assert.ok(!ids.has(key));
    ids.add(key);
  };
  for (const row of audit.bitRateRequests) {
    unique(row.requestID);
    assert.equal(row.outcome, 'completed');
    assert.equal(row.failure, null);
    assert.equal(row.profileLinkUnambiguous, true);
    for (const at of [row.requestedAt, row.receipt.acceptedAt, row.completedAt]) boundedTime(at);
    assert.ok(
      row.requestedAt <= row.receipt.acceptedAt && row.receipt.acceptedAt <= row.completedAt,
    );
    assert.equal(row.targetBitRate, row.receipt.bitRate);
    assert.equal(row.receipt.publishingGeneration, format.publishingGeneration);
    uuid(row.receipt.configurationID);
    uuid(row.receipt.encoderSessionID);
    fixtureFrameID(row.receipt.lastSubmittedSourcePTS);
  }
  const initialRates = audit.bitRateRequests.filter((r) => r.profileRequestID === null);
  assert.equal(initialRates.length, 1);
  assert.deepEqual(normalizeRate(initialRates[0].receipt), bootstrap.receipt);
  boundedTime(bootstrap.acknowledgedAt);
  boundedTime(bootstrap.at);
  assert.ok(
    initialRates[0].completedAt <= bootstrap.acknowledgedAt &&
      bootstrap.acknowledgedAt <= bootstrap.at,
  );
  const applied = quality.events.filter((e) => e.kind === 'applied');
  assert.equal(applied.length, audit.profileRequests.length);
  assert.equal(format.receipts.length, applied.length);
  const applications = audit.profileRequests.map((row, index) => {
    unique(row.requestID);
    const event = applied[index],
      application = event.application;
    unique(application.id);
    assert.equal(row.outcome, 'completed');
    assert.equal(row.failure, null);
    assert.deepEqual(row.receipt, event.profileReceipt);
    assert.deepEqual(row.receipt, format.receipts[index]);
    assert.equal(row.targetProfile, event.action.profileID);
    assert.equal(row.targetProfile, event.profileID);
    sameID(application.attemptID, audit.scope.publishingAttemptID);
    assert.equal(application.fromRevision, event.action.fromRevision);
    assert.equal(event.revision, String(BigInt(application.fromRevision) + 1n));
    assert.equal(application.candidateID, event.action.candidateID);
    if (event.action.kind === 'reset') {
      assert.equal(application.candidateID, null);
      assert.equal(event.action.candidateID, null);
      assert.ok(index > 0, 'Reset requires prior measured trial');
      // The native fixture retains its closed historical measurement for audit.
      // It does not make that measurement current authority for a reset.
      if (row.candidateMeasurementID !== null)
        sameID(row.candidateMeasurementID, applied[index - 1].application.candidateID);
    } else assert.equal(row.candidateMeasurementID, application.candidateID);
    const terminal = row.terminalProbeRead;
    for (const at of [
      row.requestedAt,
      row.completedAt,
      row.receipt.acknowledgedAt,
      terminal.startedAt,
      terminal.completedAt,
      application.admittedAt,
      event.acknowledgedAt,
      event.at,
    ])
      boundedTime(at);
    time(application.completionDeadline);
    time(event.action.validUntil);
    assert.ok(application.admittedAt <= event.action.validUntil);
    assert.ok(Math.abs(application.completionDeadline - application.admittedAt - 2) < 1e-6);
    assert.ok(
      application.admittedAt <= row.requestedAt && row.requestedAt <= row.receipt.acknowledgedAt,
    );
    assert.ok(
      row.receipt.acknowledgedAt <= row.completedAt && row.completedAt <= terminal.startedAt,
    );
    assert.ok(terminal.startedAt <= terminal.completedAt);
    const rates = audit.bitRateRequests.filter((r) => r.profileRequestID === row.requestID);
    assert.equal(rates.length, 1);
    const rate = rates[0];
    assert.ok(terminal.completedAt <= rate.requestedAt && rate.completedAt <= event.acknowledgedAt);
    assert.ok(
      event.acknowledgedAt <= application.completionDeadline && event.acknowledgedAt <= event.at,
    );
    sameID(rate.receipt.encoderSessionID, row.receipt.encoderSessionID);
    assert.deepEqual(normalizeRate(rate.receipt), event.receipt);
    assert.equal(event.receipt.bitRate, event.action.bitRate);
    if (event.action.kind === 'trial') {
      uuid(row.candidateMeasurementID);
      assert.equal(row.authorityPermitted, true);
      assert.equal(row.probeAuthorityPermitted, true);
      assert.equal(row.currentProbeActive, true);
    }
    return {
      requestID: row.requestID,
      applicationID: application.id,
      candidateID: application.candidateID,
      target: row.targetProfile,
      requestedAt: row.requestedAt,
      acknowledgedAt: event.acknowledgedAt,
      profileReceipt: row.receipt,
      receipt: event.receipt,
      application,
    };
  });
  assert.equal(audit.bitRateRequests.length, applied.length + 1);
  return {
    scope: audit.scope,
    startup,
    bootstrap,
    applications,
    nativeLifecycleReceiptsMatched: true,
    upgradeAuthorized: false,
  };
}
