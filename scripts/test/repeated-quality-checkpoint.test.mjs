import assert from 'node:assert/strict';
import test from 'node:test';
import { repeatedMeasuredPolicyFixture } from './fixtures/repeated-measured-policy-evidence.mjs';
const { RepeatedQualityCheckpoint } = await import('../repeated-quality-checkpoint.mjs').catch(
  (e) => {
    if (e.code !== 'ERR_MODULE_NOT_FOUND') throw e;
    return {};
  },
);
function fixture() {
  const f = repeatedMeasuredPolicyFixture();
  const checkpoint = (end = f.quality.events.length) => ({
    formatVersion: 1,
    mode: 'repeated',
    publishingAttemptID: f.scope.publishingAttemptID.toLowerCase(),
    eventCount: end,
    closed: f.quality.events[end - 1].closed,
    quality: {
      ...structuredClone(f.quality),
      events: structuredClone(f.quality.events.slice(0, end)),
    },
  });
  const through = (revision, end) =>
    f.quality.events.findIndex(
      (e) => e.kind === 'evaluated' && e.revision === revision && e.window.end === end,
    ) + 1;
  return { f, checkpoint, through };
}
test('live checkpoint retains original indices and waits for a whole post-confirmation source window', () => {
  assert.equal(typeof RepeatedQualityCheckpoint, 'function');
  const { f, checkpoint, through } = fixture();
  const tracker = new RepeatedQualityCheckpoint(f.scope.publishingAttemptID);
  tracker.observe(checkpoint(through('1', 145)));
  assert.equal(tracker.claimNextReady(), null);
  tracker.observe(checkpoint(through('1', 150)));
  assert.equal(tracker.claimNextReady(), null);
  tracker.observe(checkpoint(through('1', 154)));
  const ready = tracker.claimNextReady();
  assert.equal(ready.campaign, '1');
  assert.equal(ready.trialRevision, '1');
  assert.equal(
    f.quality.events[ready.confirmedEventIndex].reasons.includes('trialConfirmed'),
    true,
  );
  assert.equal(f.quality.events[ready.readyEventIndex].window.end, 154);
  assert.equal(tracker.claimNextReady(), null);
  tracker.observe(checkpoint(through('3', 214)));
  assert.equal(tracker.claimNextReady().campaign, '2');
  assert.equal(tracker.claimNextReady(), null);
  tracker.observe(checkpoint());
  assert.equal(tracker.reconcile(f.quality).liveCheckpointReconciled, true);
});
test('coalesced prefixes can skip polls and identical polls are harmless', () => {
  const { f, checkpoint, through } = fixture(),
    tracker = new RepeatedQualityCheckpoint(f.scope.publishingAttemptID);
  tracker.observe(checkpoint(1));
  tracker.observe(checkpoint(through('1', 154)));
  tracker.observe(checkpoint(through('1', 154)));
  assert.equal(tracker.claimNextReady().campaign, '1');
});
for (const [name, mutate] of [
  ['wrong attempt', (c) => (c.publishingAttemptID = 'ffffffff-ffff-4fff-8fff-ffffffffffff')],
  ['wrong version', (c) => (c.formatVersion = 2)],
  ['wrong mode', (c) => (c.mode = 'single')],
  ['overflow', (c) => (c.quality.overflow = true)],
  ['event count', (c) => c.eventCount++],
  [
    'missing original bootstrap',
    (c) => {
      c.quality.events.shift();
      c.eventCount--;
    },
  ],
  ['closed while active', (c) => (c.closed = true)],
])
  test(`rejects live checkpoint ${name}`, () => {
    const { f, checkpoint, through } = fixture(),
      tracker = new RepeatedQualityCheckpoint(f.scope.publishingAttemptID),
      c = checkpoint(through('1', 154));
    mutate(c);
    assert.throws(() => tracker.observe(c));
  });
test('original prefix cannot change, shrink, or be mutated through caller aliases', () => {
  const { f, checkpoint, through } = fixture(),
    tracker = new RepeatedQualityCheckpoint(f.scope.publishingAttemptID),
    c = checkpoint(through('1', 154));
  tracker.observe(c);
  c.quality.events[0].at++;
  assert.throws(() => tracker.observe(c));
  assert.throws(() => tracker.observe(checkpoint(1)));
  tracker.observe(checkpoint());
  assert.throws(() => tracker.observe(checkpoint(through('3', 214))));
});
test('closed checkpoint cannot schedule a late fault and final history must match', () => {
  const { f, checkpoint, through } = fixture(),
    tracker = new RepeatedQualityCheckpoint(f.scope.publishingAttemptID);
  tracker.observe(checkpoint(through('1', 154)));
  tracker.claimNextReady();
  tracker.observe(checkpoint());
  assert.equal(tracker.claimNextReady(), null);
  const bad = structuredClone(f.quality);
  bad.events[1].at++;
  assert.throws(() => tracker.reconcile(bad));
});
test('a session failure is an explicit abort even before the joined terminal checkpoint', () => {
  const { f, checkpoint, through } = fixture();
  const tracker = new RepeatedQualityCheckpoint(f.scope.publishingAttemptID);
  const value = checkpoint(through('1', 154));
  value.quality.events.push({
    ...structuredClone(value.quality.events.at(-1)),
    kind: 'failed',
    closed: true,
    at: 155,
  });
  value.eventCount++;
  assert.equal(value.closed, false);
  assert.throws(() => tracker.observe(value), /Live quality failed/);
});
for (const mutation of [
  'candidateBeforeTrial',
  'resetAction',
  'actionFromRevision',
  'applicationFromRevision',
  'actionCandidate',
]) {
  test(`fault scheduling requires original trial causality: ${mutation}`, () => {
    const { f, checkpoint, through } = fixture();
    const tracker = new RepeatedQualityCheckpoint(f.scope.publishingAttemptID);
    const value = checkpoint(through('1', 154));
    const events = value.quality.events;
    const trial = events.find((e) => e.kind === 'applied' && e.revision === '1');
    const candidate = events.find((e) => e.kind === 'candidate' && e.revision === '1');
    if (mutation === 'candidateBeforeTrial') {
      events.splice(events.indexOf(candidate), 1);
      candidate.at = trial.at;
      events.splice(events.indexOf(trial), 0, candidate);
    } else if (mutation === 'resetAction') trial.action.kind = 'reset';
    else if (mutation === 'actionFromRevision') trial.action.fromRevision = '2';
    else if (mutation === 'actionCandidate')
      trial.action.candidateID = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
    else
      for (const row of events.filter((e) => e.revision === '1'))
        row.application.fromRevision = '2';
    tracker.observe(value);
    assert.equal(tracker.claimNextReady(), null);
  });
}
for (const field of [
  'receipt',
  'profileReceipt',
  'acknowledgedAt',
  'applicationID',
  'emptyReceipts',
]) {
  test(`fault scheduling requires present native ownership: ${field}`, () => {
    const { f, checkpoint, through } = fixture();
    const tracker = new RepeatedQualityCheckpoint(f.scope.publishingAttemptID);
    const value = checkpoint(through('1', 154));
    for (const row of value.quality.events.filter((e) => e.revision === '1')) {
      if (field === 'applicationID') delete row.application.id;
      else if (field === 'emptyReceipts') {
        row.receipt = {};
        row.profileReceipt = {};
      } else delete row[field];
    }
    tracker.observe(value);
    assert.equal(tracker.claimNextReady(), null);
  });
}
for (const mutation of ['candidate', 'receipt', 'source', 'revision', 'unhealthy'])
  test(`cannot schedule using foreign ${mutation}`, () => {
    const { f, checkpoint, through } = fixture(),
      tracker = new RepeatedQualityCheckpoint(f.scope.publishingAttemptID),
      c = checkpoint(through('1', 154));
    const row = c.quality.events.at(-1);
    if (mutation === 'candidate')
      row.application.candidateID = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
    if (mutation === 'receipt') row.receipt.bitRate++;
    if (mutation === 'source') row.source.attemptID = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
    if (mutation === 'revision') row.revision = '3';
    if (mutation === 'unhealthy') row.state = 'degraded';
    tracker.observe(c);
    assert.equal(tracker.claimNextReady(), null);
  });
