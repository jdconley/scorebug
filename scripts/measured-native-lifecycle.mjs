import { qualifyCapacityPressureDecrease } from './capacity-pressure-decrease.mjs';
import { assertRecoveryProbeAcceptanceHistory } from './recovery-probe-observation.mjs';
import assert from 'node:assert/strict';
import { fixtureFrameID } from './video-observation-qualification.mjs';
import { qualifyNativeProfileTransitions } from './native-profile-transitions.mjs';

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
 * Legacy profileQualification comes from the measured native-frame validator.
 * Explicit repeated240 calls replay raw media/decoded IDs again and compare any
 * supplied summary, retaining the original global quality event indices.
 * The invalid aggregate fixed-format proof remains unchanged and is never qualified.
 */
export function qualifyMeasuredNativeLifecycle({
  lifecycle: audit,
  quality,
  format,
  snapshot,
  startupFormat: fixed,
  profileQualification,
  sequence = 'measured240',
  liveIDs,
  probePolicy = 'local-zero-loss-v1',
  recovery = false,
  capacityDecrease = false,
}) {
  assert.ok(
    ['measured240', 'repeated240'].includes(sequence),
    'Unknown measured lifecycle sequence',
  );
  assert.ok(
    ['local-zero-loss-v1', 'recovery-budget-v1'].includes(probePolicy),
    'Unknown lifecycle probe policy',
  );
  assert.equal(typeof recovery, 'boolean', 'Recovery context must be boolean');
  assert.equal(typeof capacityDecrease, 'boolean');
  assert(
    !capacityDecrease ||
      (recovery && probePolicy === 'recovery-budget-v1' && sequence === 'measured240'),
    'Capacity decrease requires explicit recovery-budget lifecycle',
  );
  const decrease = capacityDecrease
    ? qualifyCapacityPressureDecrease({ quality, snapshot })
    : undefined;
  const recoveryPolicy = probePolicy === 'recovery-budget-v1';
  assert.equal(quality.formatVersion, recoveryPolicy ? 5 : 4);
  if (recoveryPolicy) {
    assert.equal(
      sequence,
      'measured240',
      'Recovery-budget repeated lifecycle is not yet supported',
    );
    assert.equal(quality.transportPolicy, probePolicy);
  } else
    assert.ok(
      !Object.hasOwn(quality, 'transportPolicy'),
      'Historical lifecycle has new pressure policy',
    );
  const repeated = sequence === 'repeated240';
  assert.equal(format.sequence, sequence);
  if (repeated) {
    const replay = qualifyNativeProfileTransitions(format, snapshot, liveIDs, {
      sequence,
      requireFrameEvidence: true,
    });
    if (profileQualification !== undefined) assert.deepEqual(profileQualification, replay);
    profileQualification = replay;
  }
  assert.equal(profileQualification.sequence, sequence);
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
  if (recoveryPolicy) {
    assert.equal(
      audit.profileRequests.length,
      recovery ? 2 : 1,
      'Recovery-budget lifecycle requires the selected trial/reset sequence',
    );
    assert.equal(profileQualification.phases.length, recovery ? 3 : 2);
  }
  const probeEntries = [];
  for (const [index, row] of audit.profileRequests.entries()) {
    if (recoveryPolicy && index === 1) {
      // A downward reset retains the first trial's closed audit snapshots.
      // Their old preflight times are not renewed authority or fresh capacity.
      const firstRequest = audit.profileRequests[0];
      assert.deepEqual(
        row.probeBinding,
        firstRequest.probeBinding,
        'Reset changed historical probe binding',
      );
      assert.deepEqual(
        row.currentProbe,
        firstRequest.currentProbe,
        'Reset changed historical current probe',
      );
      assert.deepEqual(
        row.terminalProbeRead?.observation,
        firstRequest.terminalProbeRead?.observation,
        'Reset changed historical terminal probe',
      );
    }
    const values = [
      [row.probeBinding?.observation, row.probeBinding?.boundAt],
      [row.currentProbe, row.requestedAt],
      [row.terminalProbeRead?.observation, row.terminalProbeRead?.completedAt],
    ];
    for (const [sample, observedAt] of values) {
      if (recoveryPolicy) {
        assert.ok(sample, 'Missing recovery lifecycle probe');
        const bound = values[0][0];
        sameID(sample.id, bound.id);
        for (const key of [
          'publishingGeneration',
          'campaign',
          'stage',
          'bitRate',
          'startedAt',
          'policy',
        ])
          assert.equal(sample[key], bound[key], `Lifecycle probe ${key} mismatch`);
      }
      if (sample != null) probeEntries.push({ sample, observedAt });
    }
  }
  if (probeEntries.length)
    assertRecoveryProbeAcceptanceHistory(probeEntries, { policy: probePolicy });
  time(audit.closedAt);
  time(snapshot.monotonicAnchor);
  assert.ok(audit.closedAt >= snapshot.monotonicAnchor);
  const boundedTime = (n) => {
    time(n);
    assert.ok(n >= snapshot.monotonicAnchor && n <= audit.closedAt);
  };
  assert.equal(quality.overflow, false);
  assert.ok(Array.isArray(quality.events) && quality.events.length <= 512);
  if (repeated || recoveryPolicy) {
    if (repeated) assert.equal(quality.formatVersion, 4);
    assert.equal(quality.measuredSourceEvaluationEnabled, true);
    for (const [index, event] of quality.events.entries()) {
      time(event.at);
      if (index > 0)
        assert.ok(event.at >= quality.events[index - 1].at, 'Quality timeline regressed');
    }
    assert.equal(
      audit.profileRequests.length,
      repeated ? 4 : recovery ? 2 : 1,
      'Lifecycle requires the selected profile writes',
    );
    assert.equal(
      audit.bitRateRequests.length,
      repeated ? 5 : recovery ? 3 : 2,
      'Lifecycle requires the selected bitrate writes',
    );
  }
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
  const configurations = new Set();
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
    if (repeated || recoveryPolicy) {
      const id = uuid(row.receipt.configurationID);
      assert.ok(!configurations.has(id), 'Reused native bitrate configuration');
      configurations.add(id);
    }
    uuid(row.receipt.encoderSessionID);
    fixtureFrameID(row.receipt.lastSubmittedSourcePTS);
  }
  const initialRates = audit.bitRateRequests.filter((r) => r.profileRequestID === null);
  assert.equal(initialRates.length, 1);
  if (repeated || recoveryPolicy) assert.equal(initialRates[0], audit.bitRateRequests[0]);
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
  const candidates = quality.events.filter((e) => e.kind === 'candidate');
  if (repeated || recoveryPolicy)
    assert.equal(
      candidates.length,
      repeated ? 2 : 1,
      'Lifecycle requires the selected owned trials',
    );
  const candidateIDs = new Set();
  const applications = audit.profileRequests.map((row, index) => {
    unique(row.requestID);
    const event = applied[index],
      application = event.application;
    if (repeated || recoveryPolicy) {
      const trial = index % 2 === 0;
      assert.equal(event.closed, false);
      assert.equal(event.action.kind, trial ? 'trial' : capacityDecrease ? 'decrease' : 'reset');
      assert.equal(event.profileID, trial ? '360p30' : '240p30');
      assert.equal(event.action.bitRate, trial ? 600000 : 350000);
      assert.equal(application.fromRevision, String(index), 'Skipped original applied revision');
      assert.equal(event.revision, String(index + 1));
      const prior = index === 0 ? bootstrap : applied[index - 1];
      assert.ok(
        prior.at <= application.admittedAt,
        'Native applications overlap prior acknowledgment',
      );
      assert.ok(row.requestedAt < event.action.validUntil, 'Native request after action expiry');
      if (trial) {
        const candidate = candidates[index / 2];
        const id = uuid(application.candidateID);
        assert.ok(!candidateIDs.has(id), 'Reused candidate across repeated trials');
        candidateIDs.add(id);
        assert.equal(candidate.closed, false);
        assert.equal(candidate.revision, event.revision);
        assert.equal(candidate.profileID, event.profileID);
        for (const key of ['action', 'application', 'profileReceipt', 'receipt'])
          assert.deepEqual(
            candidate[key],
            event[key],
            `Candidate ${key} differs from applied event`,
          );
        sameID(candidate.candidate.id, application.candidateID);
        assert.equal(candidate.candidate.appliedRevision, application.fromRevision);
        boundedTime(candidate.at);
        boundedTime(candidate.evaluatedAt);
        assert.ok(candidate.evaluatedAt <= application.admittedAt);
        const candidateIndex = quality.events.indexOf(candidate);
        assert.ok(candidateIndex > quality.events.indexOf(event));
        assert.ok(
          candidateIndex <
            (applied[index + 1]
              ? quality.events.indexOf(applied[index + 1])
              : quality.events.length),
        );
      } else {
        assert.equal(row.authorityPermitted, false);
        assert.equal(row.probeAuthorityPermitted, false);
        assert.equal(row.currentProbeActive, false);
      }
    }
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
    if (event.action.kind === 'reset' || (capacityDecrease && event.action.kind === 'decrease')) {
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
    if (repeated || recoveryPolicy)
      assert.equal(rate, audit.bitRateRequests[index + 1], 'Native bitrate writes reordered');
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
      ...(repeated
        ? {
            fromRevision: application.fromRevision,
            revision: event.revision,
            qualityEventIndex: quality.events.indexOf(event),
          }
        : {}),
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
    ...(repeated ? { sequence, repeatedPolicyQualified: false, recoveryQualified: false } : {}),
    scope: audit.scope,
    startup,
    bootstrap,
    applications,
    ...(recoveryPolicy ? { probePolicy } : {}),
    ...(capacityDecrease ? { capacityDecrease: decrease } : {}),
    nativeLifecycleReceiptsMatched: true,
    upgradeAuthorized: false,
  };
}
