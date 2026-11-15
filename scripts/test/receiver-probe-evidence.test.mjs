import assert from 'node:assert/strict';
import test from 'node:test';
import { createHmac } from 'node:crypto';
import {
  recordReceiverProbeEvidence,
  qualifyReceiverProbeEvidence,
} from '../receiver-probe-evidence.mjs';
const secret = 'fixture-installation-secret';
const attempt = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',
  id = 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff';
const scope = {
  gameId: 'match',
  generation: 1,
  selection: {
    workerId: 'mac',
    outputId: 'local',
    captureDeviceId: 'phone',
    recordingId: 'archive',
  },
};
const native = {
  matchID: 'match',
  broadcastGeneration: 1,
  recordingID: 'archive',
  publishingAttemptID: attempt.toUpperCase(),
};
const hmac = (value) => createHmac('sha256', secret).update(JSON.stringify(value)).digest('hex');
const identity = JSON.stringify(['match', 'mac', 'local', 'phone', 'archive', 1]);
const path = `scorebug-${hmac(['scorebug-ingest-v1', 'installation', '']).slice(0, 16)}-${hmac(['scorebug-ingest-v1', 'path', identity]).slice(0, 32)}`;
const probe = (messages = 1) => ({
  convention: 'mpegts-null-probe-v1',
  id,
  publishingGeneration: '7',
  bitRate: 1000000,
  deliveredMessages: String(messages),
  deliveredPayloadBytes: String(messages * 1316),
  nextSequence: String(messages),
  pendingPackets: 0,
  observedAtNanoseconds: String(messages * 1000000000),
  firstDeliveredAtNanoseconds: '500000000',
  lastDeliveredAtNanoseconds: String(messages * 1000000000 - 100000000),
});
const connection = () => ({
  id: '11111111-2222-4333-8444-555555555555',
  state: 'publish',
  path,
  query: `sbp1=${attempt}.${hmac(['scorebug-publish-attempt-v1', path, attempt])}`,
  user: 'private-user',
  scorebugBandwidthProbe: probe(),
});
const listing = (c) => ({ pageCount: 1, itemCount: 1, items: [c] });
const accepted = {
  id: id.toUpperCase(),
  publishingGeneration: '7',
  acceptedPayloadBytes: 2632,
  reason: 'transportPressure',
};
const timing = (n) => ({
  startedAtMilliseconds: n * 1000 + 100,
  receivedAtMilliseconds: n * 1000 + 110,
});
function fixture() {
  const m = new Map();
  for (const n of [1, 2]) {
    const c = connection();
    c.scorebugBandwidthProbe = probe(n);
    recordReceiverProbeEvidence(m, listing(c), scope, secret, timing(n));
  }
  return [...m.values()];
}
const qualify = (records) => qualifyReceiverProbeEvidence(records, native, accepted);
test('binds receiver bytes to authenticated publication and native probe without capacity admission', () => {
  const records = fixture(),
    r = qualify(records);
  assert.equal(r.deliveredPayloadBytes, 2632);
  assert.equal(r.deliveredMessages, 2);
  assert.equal(r.receiverCapacityQualified, false);
  assert.equal(r.probeId, id);
  assert.equal(r.observationCount, 2);
  assert.ok(!JSON.stringify(records).includes('private'));
  assert.ok(!JSON.stringify(records).includes('sbp1='));
});
test('rejects unauthenticated or duplicate publisher identity and unavailable proof', () => {
  const c = connection();
  c.query = c.query.slice(0, -1) + 'x';
  assert.throws(() => recordReceiverProbeEvidence(new Map(), listing(c), scope, secret, timing(1)));
  const l = { pageCount: 1, itemCount: 2, items: [connection(), connection()] };
  assert.throws(() => recordReceiverProbeEvidence(new Map(), l, scope, secret, timing(1)));
  const missing = connection();
  delete missing.scorebugBandwidthProbe;
  const m = new Map();
  recordReceiverProbeEvidence(m, listing(missing), scope, secret, timing(1));
  assert.equal(m.size, 0);
  assert.throws(() => qualify([]));
});
const mutations = {
  count: (r) => {
    r[1].probe.deliveredMessages = '3';
  },
  bytes: (r) => {
    r[1].probe.deliveredPayloadBytes = '1316';
  },
  sequence: (r) => {
    r[1].probe.nextSequence = '3';
  },
  invalid: (r) => {
    r[1].probe.invalidReason = 'sequence';
  },
  partial: (r) => {
    r[1].probe.pendingPackets = 1;
  },
  id: (r) => {
    r[1].probe.id = attempt;
  },
  generation: (r) => {
    r[1].probe.publishingGeneration = '8';
  },
  rate: (r) => {
    r[1].probe.bitRate = 2000000;
  },
  reversed: (r) => {
    r.reverse();
  },
  future: (r) => {
    r[1].probe.lastDeliveredAtNanoseconds = '9999999999';
  },
  staleClock: (r) => {
    r[1].probe.observedAtNanoseconds = r[0].probe.observedAtNanoseconds;
    r[1].probe.lastDeliveredAtNanoseconds = '900000000';
  },
  firstChanges: (r) => {
    r[1].probe.firstDeliveredAtNanoseconds = '600000000';
  },
  elapsedRequest: (r) => {
    r[1].request.receivedAtMilliseconds += 1600;
  },
  nonfinite: (r) => {
    r[0].request.startedAtMilliseconds = NaN;
  },
  wrongMatch: (r) => {
    r[1].publication.gameId = 'other';
  },
  wrongAttempt: (r) => {
    r[1].publication.publishingAttemptId = id;
  },
  replacedConnection: (r) => {
    r[1].publication.publicationId = id;
  },
  huge: (r) => {
    r[1].probe.deliveredMessages = '9'.repeat(10000);
  },
  receiverOvercounts: (r) => {
    r[1].probe.deliveredMessages = '3';
    r[1].probe.deliveredPayloadBytes = '3948';
    r[1].probe.nextSequence = '3';
  },
  receiverUndercounts: (r) => {
    r[1].probe.deliveredMessages = '1';
    r[1].probe.deliveredPayloadBytes = '1316';
    r[1].probe.nextSequence = '1';
    r[1].probe.lastDeliveredAtNanoseconds = '900000000';
  },
};
for (const [name, mutate] of Object.entries(mutations))
  test(`receiver evidence rejects ${name}`, () => {
    const r = fixture();
    mutate(r);
    assert.throws(() => qualify(r));
  });
test('collection copies snapshots and bounds retained history', () => {
  const c = connection(),
    m = new Map();
  recordReceiverProbeEvidence(m, listing(c), scope, secret, timing(1));
  c.scorebugBandwidthProbe.id = attempt;
  assert.equal([...m.values()][0].probe.id, id);
  const full = new Map(Array.from({ length: 2048 }, (_, i) => [i, {}]));
  assert.throws(() =>
    recordReceiverProbeEvidence(full, listing(connection()), scope, secret, timing(1)),
  );
});
test('receiver delivery cannot grow behind its previous observed timestamp', () => {
  const records = fixture();
  records[1].probe.lastDeliveredAtNanoseconds = records[0].probe.lastDeliveredAtNanoseconds;
  assert.throws(() => qualify(records));
});
test('pending receiver packets cannot silently disappear without a completed message', () => {
  const records = fixture();
  records[0].probe.pendingPackets = 1;
  Object.assign(records[1].probe, {
    deliveredMessages: '1',
    deliveredPayloadBytes: '1316',
    nextSequence: '1',
    lastDeliveredAtNanoseconds: records[0].probe.lastDeliveredAtNanoseconds,
  });
  assert.throws(() =>
    qualifyReceiverProbeEvidence(records, native, { ...accepted, acceptedPayloadBytes: 1316 }),
  );
});
test('first completed delivery cannot predate a zero-message observation', () => {
  const records = fixture();
  Object.assign(records[0].probe, {
    deliveredMessages: '0',
    deliveredPayloadBytes: '0',
    nextSequence: '0',
    pendingPackets: 4,
  });
  delete records[0].probe.firstDeliveredAtNanoseconds;
  delete records[0].probe.lastDeliveredAtNanoseconds;
  assert.throws(() => qualify(records));
});
test('authenticated collection retains staged metadata while redacting credentials', () => {
  const c = connection(),
    m = new Map();
  Object.assign(c.scorebugBandwidthProbe, {
    convention: 'mpegts-null-probe-v2',
    stage: 2,
    totalDeliveredPayloadBytes: '3948',
    firstDeliveredAtNanoseconds: '900000000',
  });
  recordReceiverProbeEvidence(m, listing(c), scope, secret, timing(1));
  const record = [...m.values()][0];
  assert.equal(record.probe.stage, 2);
  assert.equal(record.probe.totalDeliveredPayloadBytes, '3948');
  assert.ok(!JSON.stringify(record).includes(secret));
  assert.ok(!JSON.stringify(record).includes('sbp1='));
  c.scorebugBandwidthProbe.stage = 3;
  assert.equal(record.probe.stage, 2);
});
for (const patch of [
  { stage: 1 },
  { totalDeliveredPayloadBytes: '1316' },
  { convention: 'mpegts-null-probe-v2', stage: 0, totalDeliveredPayloadBytes: '1316' },
  { convention: 'mpegts-null-probe-v2', stage: 33, totalDeliveredPayloadBytes: '1316' },
  { convention: 'mpegts-null-probe-v2', stage: 1, totalDeliveredPayloadBytes: '01316' },
  { convention: 'mpegts-null-probe-v2', stage: 1, totalDeliveredPayloadBytes: '0' },
  {
    convention: 'mpegts-null-probe-v2',
    stage: 1,
    totalDeliveredPayloadBytes: '16776368',
    pendingPackets: 1,
  },
])
  test(`collection rejects malformed staged metadata ${JSON.stringify(patch)}`, () => {
    const c = connection();
    Object.assign(c.scorebugBandwidthProbe, { firstDeliveredAtNanoseconds: '900000000' }, patch);
    assert.throws(() =>
      recordReceiverProbeEvidence(new Map(), listing(c), scope, secret, timing(1)),
    );
  });
