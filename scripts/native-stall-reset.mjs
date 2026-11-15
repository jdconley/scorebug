import assert from 'node:assert/strict';
import { qualifyNativeStallSignal } from './native-controlled-stall.mjs';
import { qualifyNativeProfileTransitions } from './native-profile-transitions.mjs';
import { fixtureFrameID } from './video-observation-qualification.mjs';
const finite = (v) => Number.isFinite(v) && v >= 0 && v <= 1e12;
export function qualifyNativeStallReset(input) {
  const { quality, format, snapshot, liveIDs, scope } = input;
  const transitions = qualifyNativeProfileTransitions(format, snapshot, liveIDs, {
    sequence: 'stall540',
    requireFrameEvidence: true,
  });
  assert.deepEqual(scope, snapshot.scope);
  const boots = quality.events.filter((e) => e.kind === 'bootstrap');
  const stalls = quality.events.filter((e) => e.kind === 'decoderStall');
  const writes = quality.events.filter((e) => e.kind === 'applied');
  assert.equal(boots.length, 1);
  assert.equal(stalls.length, 1);
  assert.equal(writes.length, 1);
  assert(!quality.events.some((e) => e.kind === 'failed' || e.kind === 'skipped'));
  const boot = boots[0],
    stall = stalls[0],
    write = writes[0];
  assert.equal(quality.events[0], boot);
  assert(quality.events.indexOf(stall) < quality.events.indexOf(write));
  const timing = qualifyNativeStallSignal(input, stall);
  const profile = transitions.receipts[0],
    old = boot.receipt,
    next = write.receipt;
  assert.equal(boot.profileID, '540p30');
  assert.equal(old.bitRate, 1500000);
  assert.equal(old.encoderSessionID, format.encoderSessions[0].encoderSessionID);
  assert.equal(old.generation, format.publishingGeneration);
  assert(finite(old.acceptedAt) && old.acceptedAt >= format.phases[0].firstObservedAt);
  assert(finite(boot.acknowledgedAt) && boot.acknowledgedAt >= old.acceptedAt);
  assert(fixtureFrameID(old.lastSubmittedPTS) >= transitions.phases[0].firstFrame);
  assert(fixtureFrameID(old.lastSubmittedPTS) <= transitions.phases[0].lastFrame);
  assert.deepEqual(write.profileReceipt, profile);
  assert.equal(next.encoderSessionID, profile.encoderSessionID);
  assert.equal(next.generation, old.generation);
  assert.equal(next.bitRate, 350000);
  assert.notEqual(next.configurationID, old.configurationID);
  assert.match(next.configurationID, /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i);
  assert(fixtureFrameID(next.lastSubmittedPTS) >= fixtureFrameID(profile.firstNewSourcePTS));
  assert(fixtureFrameID(next.lastSubmittedPTS) <= transitions.phases[1].lastFrame);
  assert(finite(next.acceptedAt) && next.acceptedAt >= profile.acknowledgedAt);
  const action = write.action,
    application = write.application;
  assert.equal(action.kind, 'reset');
  assert.equal(action.profileID, '240p30');
  assert.equal(action.bitRate, 350000);
  assert.equal(action.fromRevision, '0');
  assert.equal(application.fromRevision, '0');
  assert.equal(application.windowSequence, stall.decoderStall.sequence);
  assert.equal(application.attemptID.toLowerCase(), scope.publishingAttemptID.toLowerCase());
  for (const v of [
    application.admittedAt,
    application.completionDeadline,
    action.validUntil,
    write.acknowledgedAt,
  ])
    assert(finite(v));
  assert(
    application.admittedAt >= stall.evaluatedAt && application.admittedAt <= action.validUntil,
  );
  assert(
    application.completionDeadline > application.admittedAt &&
      application.completionDeadline <= application.admittedAt + 2,
  );
  assert(profile.acknowledgedAt >= application.admittedAt);
  assert(
    write.acknowledgedAt >= next.acceptedAt &&
      write.acknowledgedAt <= application.completionDeadline,
  );
  assert(format.phases[1].firstObservedAt >= application.admittedAt);
  assert(format.encoderSessions[1].firstCompletedAt >= application.admittedAt);
  let applied = false;
  for (const event of quality.events) {
    if (event === write) applied = true;
    const expected = applied ? write : boot;
    assert.deepEqual(event.receipt, expected.receipt, 'Unexpected native receipt');
    assert.equal(event.acknowledgedAt, expected.acknowledgedAt);
    assert.equal(event.profileID, applied ? '240p30' : '540p30');
    assert.equal(event.revision, applied ? '1' : '0');
    if (applied) assert.deepEqual(event.profileReceipt, profile);
  }
  return {
    ...timing,
    higherProfileResetWriteQualified: true,
    automaticRecoveryQualified: false,
    nativeApplicationSeconds: write.acknowledgedAt - application.admittedAt,
    decisionToFirstMinimumFrameSeconds: format.phases[1].firstObservedAt - stall.evaluatedAt,
    decisionToAcknowledgmentSeconds: write.acknowledgedAt - stall.evaluatedAt,
    transitions,
  };
}
