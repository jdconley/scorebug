import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { nativeCadenceReports, qualifyNativeCadenceReports } from '../native-cadence-reports.mjs';
const environment = {
  SCOREBUG_TEST_CADENCE_REPORTS: '1',
  SCOREBUG_TEST_LIVE_PROFILE: '240p30',
  SCOREBUG_TEST_MOTION_FIXTURE: 'blocks16',
  SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
};
const options = {
  environment,
  streaming: true,
  requirePublication: true,
  requireProcessing: true,
  holdSeconds: 90,
};
test('cadence mode is explicit fixed minimum and bounded', () => {
  assert.equal(nativeCadenceReports({ environment: {} }), false);
  assert.equal(nativeCadenceReports(options), true);
  for (const change of [
    { streaming: false },
    { requirePublication: false },
    { requireProcessing: false },
    { holdSeconds: 121 },
    { environment: { ...environment, SCOREBUG_TEST_CADENCE_REPORTS: '' } },
    { environment: { ...environment, SCOREBUG_TEST_LIVE_PROFILE: '360p30' } },
    { environment: { ...environment, SCOREBUG_TEST_NATIVE_QUALITY: '1' } },
    { environment: { ...environment, SCOREBUG_TEST_PROFILE_TRANSITIONS: 'low240' } },
  ])
    assert.throws(() => nativeCadenceReports({ ...options, ...change }));
});
function fixture() {
  const response = JSON.parse(
    readFileSync(
      new URL('../../packages/protocol/fixtures/decoder-cadence-v1.json', import.meta.url),
    ),
  );
  response.status.decoderCadenceAgeUpperBoundMs = 100;
  const scope = {
    matchID: 'match',
    broadcastGeneration: 2,
    publishingAttemptID: response.status.publication.publishingAttemptId,
  };
  const audit = { formatVersion: 1, closed: true, overflow: false, invalid: false, rows: [] };
  for (let i = 0; i <= 400; i++)
    audit.rows.push({
      response: structuredClone(response),
      expectedAttempt: scope.publishingAttemptID,
      receivedUptime: 100 + i / 10,
      evaluatedUptime: 100 + i / 10 + 0.002,
      requestSeconds: 0.01,
      residenceSeconds: 0.002,
      sampleAgeSeconds: 0.112,
      observedStall: false,
    });
  return { audit, scope };
}
test('reconciles actual helper bounds without asserting stall response qualification', () => {
  const r = qualifyNativeCadenceReports(fixture());
  assert.equal(r.withinBudgetFraction, 1);
  assert.equal(r.controlledStallResponseQualified, false);
});
for (const [name, damage] of Object.entries({
  open: (x) => (x.audit.closed = false),
  overflow: (x) => (x.audit.overflow = true),
  invalid: (x) => (x.audit.invalid = true),
  age: (x) => (x.audit.rows[50].sampleAgeSeconds = 0.1),
  missingRequest: (x) => delete x.audit.rows[50].requestSeconds,
  wrongAttempt: (x) => (x.audit.rows[50].expectedAttempt = 'wrong'),
  wrongPublication: (x) =>
    (x.audit.rows[50].response.status.publication.publishingAttemptId = 'wrong'),
  wrongScope: (x) => (x.scope.matchID = 'wrong'),
  stall: (x) => (x.audit.rows[50].observedStall = true),
  short: (x) => x.audit.rows.splice(100),
  nan: (x) => (x.audit.rows[50].residenceSeconds = NaN),
  gap: (x) => x.audit.rows.splice(100, 10),
  unavailable: (x) => {
    for (const r of x.audit.rows) {
      r.sampleAgeSeconds = null;
      r.observedStall = null;
    }
  },
  stale: (x) => {
    for (const r of x.audit.rows) {
      r.response.status.decoderCadenceAgeUpperBoundMs = 300;
      r.sampleAgeSeconds = 0.312;
      r.observedStall = null;
    }
  },
}))
  test(`rejects ${name}`, () => {
    const x = fixture();
    damage(x);
    assert.throws(() => qualifyNativeCadenceReports(x));
  });
