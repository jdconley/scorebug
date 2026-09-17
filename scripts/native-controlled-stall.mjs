import assert from 'node:assert/strict';
const finite = (n) => typeof n === 'number' && Number.isFinite(n) && n >= 0;
export function nativeControlledStall({ environment, cadenceReports }) {
  const flag = environment.SCOREBUG_TEST_DECODER_STALL;
  if (flag === undefined) return false;
  assert(
    ['1', 'reset540'].includes(flag) && cadenceReports,
    'Controlled decoder stall requires the explicit cadence fixture',
  );
  return true;
}
/** Phone-local timestamps plus the conservative worker sample bound. Node fault
 * timestamps prove the owned pause duration only; their epoch is never mixed in. */
export function qualifyNativeControlledStall({ quality, audit, fault, scope }) {
  const boot = quality.events.filter((e) => e.kind === 'bootstrap'),
    stalls = quality.events.filter((e) => e.kind === 'decoderStall');
  assert.equal(boot.length, 1);
  assert.equal(boot[0].profileID, '240p30');
  assert.equal(boot[0].receipt.bitRate, 350000);
  for (const event of quality.events) {
    assert.deepEqual(event.receipt, boot[0].receipt, 'Minimum hold changed the native receipt');
    assert.equal(
      event.acknowledgedAt,
      boot[0].acknowledgedAt,
      'Minimum hold changed acknowledgment',
    );
    assert.equal(event.profileID, '240p30', 'Minimum hold changed profile');
    assert.equal(event.revision, '0', 'Minimum hold changed revision');
  }
  assert.equal(stalls.length, 1, 'One owned pause must produce one deduplicated minimum hold');
  assert(
    !quality.events.some((e) => e.kind === 'applied' || e.kind === 'failed'),
    'Minimum hold must not recreate encoder or fail live',
  );
  const event = stalls[0];
  assert.equal(event.state, 'stalled');
  assert(event.reasons.includes('stalled') && event.reasons.includes('minimumProfileInsufficient'));
  return {
    minimumHoldDecisionQualified: true,
    higherProfileResetWriteQualified: false,
    ...qualifyNativeStallSignal({ quality, audit, fault, scope }, event),
  };
}
export function qualifyNativeStallSignal(
  { quality, audit, fault, scope, expectedRevision = '0' },
  event,
) {
  assert(['0', '1'].includes(expectedRevision), 'Unsupported stall revision');
  assert(
    fault.closed === true &&
      fault.failed === false &&
      finite(fault.pauseSentAt) &&
      finite(fault.resumeSentAt),
  );
  const duration = fault.resumeSentAt - fault.pauseSentAt;
  assert(duration >= 1800 && duration <= 2500, 'Unexpected owned pause duration');
  assert(
    fault.identity.guardian.ppid === fault.identity.worker.pid &&
      fault.identity.decoder.ppid === fault.identity.guardian.pid,
  );
  assert(audit.closed === true && audit.overflow === false && audit.invalid === false);
  assert(quality.formatVersion === 4 && quality.overflow === false && quality.events.length <= 512);
  const s = event.decoderStall;
  assert.equal(event.state, 'stalled');
  assert(event.reasons.includes('stalled'));
  assert.equal(event.revision, expectedRevision);
  assert.equal(s.revision, expectedRevision);
  assert.equal(event.window, undefined);
  assert.equal(s.publishingAttemptID, scope.publishingAttemptID.toLowerCase());
  assert(
    finite(event.evaluatedAt) && finite(s.observedAtLowerBound) && finite(event.acknowledgedAt),
  );
  assert(
    s.observedAtLowerBound >= event.acknowledgedAt + 1,
    'Stall crosses encoder acknowledgment',
  );
  const sampleAge = event.evaluatedAt - s.observedAtLowerBound;
  assert(sampleAge >= 0 && sampleAge <= 0.25, 'Stale admitted stall');
  const matches = audit.rows.filter((r) => {
    const status = r.response.status,
      c = status.observation?.decoderCadence;
    return (
      r.expectedAttempt === s.publishingAttemptID &&
      status.workerId === s.workerID &&
      status.workerEpoch === s.workerEpoch &&
      status.publication?.readerId === s.readerID &&
      status.publication?.publishingAttemptId === s.publishingAttemptID &&
      status.observation?.attempt === s.workerAttempt &&
      c?.scopeID === s.scopeID &&
      String(c.progress?.lastFreshPTS) === s.lastFreshPTS &&
      r.observedStall === true &&
      r.sampleAgeSeconds !== null &&
      r.evaluatedUptime <= event.evaluatedAt &&
      event.evaluatedAt - r.evaluatedUptime <= 0.25 &&
      Math.abs(r.evaluatedUptime - r.sampleAgeSeconds - s.observedAtLowerBound) <= 0.002
    );
  });
  assert(matches.length > 0, 'Native decision has no matching raw report');
  const raw = matches.at(-1),
    progress = raw.response.status.observation.decoderCadence.progress;
  assert(progress.stalled === true && finite(progress.ageMs) && progress.ageMs >= 1000);
  const upperDelay = progress.ageMs / 1000 + sampleAge;
  assert(upperDelay <= 1.5, 'Stall decision exceeded reaction budget');
  const resumed = audit.rows.find(
    (r) =>
      r.evaluatedUptime > event.evaluatedAt &&
      r.observedStall === false &&
      r.response.status.observation?.decoderCadence?.scopeID === s.scopeID &&
      r.response.status.observation.decoderCadence.progress.lastFreshPTS > Number(s.lastFreshPTS),
  );
  assert(resumed, 'Missing resumed decoder progress');
  assert.equal(quality.events.at(-1).kind, 'stopped');
  assert.equal(quality.events.at(-1).closed, true);
  return {
    pauseMilliseconds: duration,
    triggerCadenceReportIndex: audit.rows.indexOf(raw),
    admittedSampleAgeSeconds: sampleAge,
    lastProgressToDecisionUpperBoundSeconds: upperDelay,
    nativeReceiptToDecisionSeconds: event.evaluatedAt - raw.evaluatedUptime,
    decisionToObservedRecoverySeconds: resumed.evaluatedUptime - event.evaluatedAt,
    decoderScopeID: s.scopeID,
    lastStalledPTS: s.lastFreshPTS,
  };
}
