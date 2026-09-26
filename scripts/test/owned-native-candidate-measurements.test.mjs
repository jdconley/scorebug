import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { gunzipSync } from 'node:zlib';
import { decodeFixtureBarcodes, fixtureFrameID } from '../video-observation-qualification.mjs';
import * as implementation from '../owned-native-candidate-measurements.mjs';
const readJSON = (name) => JSON.parse(readFileSync(new URL(`./fixtures/${name}`, import.meta.url)));
const provenance = readJSON('owned-candidate-LvDNAy.provenance.json');
const original = readJSON('owned-receiver-LvDNAy.provenance.json');
function load(p) {
  const compressed = readFileSync(new URL(`../../${p.fixture}`, import.meta.url));
  assert.equal(compressed.length, p.compressedBytes);
  const bytes = gunzipSync(compressed, { maxOutputLength: 8 * 1024 * 1024 });
  assert.equal(bytes.length, p.bytes);
  assert.equal(createHash('sha256').update(bytes).digest('hex'), p.sha256);
  return bytes;
}
const rawOwned = JSON.parse(load(original.native));
const options = {
  ...original.options,
  ...Object.fromEntries(
    Object.entries(provenance.inputs).map(([k, p]) =>
      k === 'decoded' ? ['liveIDs', decodeFixtureBarcodes(load(p))] : [k, JSON.parse(load(p))],
    ),
  ),
};
function fixture() {
  return structuredClone({ rawOwned, options });
}
function qualify(input = fixture()) {
  assert.equal(
    typeof implementation.qualifyOwnedNativeCandidateMeasurements,
    'function',
    'owned candidate join must exist',
  );
  return implementation.qualifyOwnedNativeCandidateMeasurements(input.rawOwned, input.options);
}
const event = (x, kind, n = 0) => x.rawOwned.events.filter((e) => e.kind === kind)[n];
test('original complete owned history retains both failed owners and joins both raw candidate costs', () => {
  const x = fixture(),
    before = structuredClone(x),
    r = qualify(x);
  assert.equal(r.eventCount, 540);
  assert.deepEqual(
    r.attempts.map((a) => a.campaign),
    ['1', '2', '3', '4'],
  );
  assert.deepEqual(
    r.attempts.map((a) => a.appliedRevision),
    ['0', '2', '2', '2'],
  );
  assert.deepEqual(
    r.attempts.map((a) => a.measurement?.frames ?? null),
    [121, null, null, 121],
  );
  assert.deepEqual(
    r.attempts.map((a) => a.baselinePhaseIndex),
    [0, 2, 2, 2],
  );
  for (const a of [r.attempts[0], r.attempts[3]]) {
    assert.equal(x.rawOwned.events[a.candidateBoundEventIndex].kind, 'candidateBound');
    assert.equal(
      x.rawOwned.events[a.candidateStartRequestedEventIndex].kind,
      'candidateStartRequested',
    );
    assert.equal(x.rawOwned.events[a.candidateJoinedEventIndex].kind, 'candidateJoined');
    assert.equal(a.measurement.sourceDuration, 4);
    assert.equal(a.measurement.maximumUnresolvedInputs, 14);
    assert.ok(a.measurement.transport.transportBytes > 0);
  }
  for (const key of [
    'receiverCapacityQualified',
    'admissionQualified',
    'recoveryQualified',
    'retryPolicyQualified',
    'upgradeAuthorized',
    'trialConfirmed',
  ])
    assert.equal(r[key], false);
  assert.deepEqual(x, before);
});

test('strict required options and trusted timing cannot be replaced by evidence selectors', () => {
  for (const key of Object.keys(options)) {
    const x = fixture();
    delete x.options[key];
    assert.throws(() => qualify(x), key);
  }
  for (const [k, v] of [
    ['skipTransport', true],
    ['resourceLimits', {}],
    ['timingProfile', 'strict1500-v1'],
    ['publishingGeneration', '2'],
  ]) {
    const x = fixture();
    x.options[k] = v;
    assert.throws(() => qualify(x), k);
  }
});

for (const [label, mutate] of [
  [
    'foreign transfer candidate',
    (x) =>
      (event(x, 'applicationTransferred').candidateID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  ],
  [
    'foreign optional acknowledgement candidate',
    (x) => (event(x, 'acknowledged').candidateID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  ],
  [
    'candidate reused across owners',
    (x) =>
      (event(x, 'candidateJoined', 1).measurement.id = event(x, 'candidateJoined').measurement.id),
  ],
  [
    'candidate reuses different live encoder',
    (x) =>
      (event(x, 'candidateJoined').measurement.encoding.encoderSessionID =
        x.options.format.encoderSessions[3].encoderSessionID),
  ],
  [
    'measurement escapes real request',
    (x) =>
      (event(x, 'candidateJoined').measurement.startedAt =
        event(x, 'candidateStartRequested').at - 0.01),
  ],
  [
    'measurement escapes real join',
    (x) =>
      (event(x, 'candidateJoined').measurement.endedAt = event(x, 'candidateJoined').at + 0.01),
  ],
  [
    'partial joined measurement',
    (x) => event(x, 'candidateJoined').measurement.encoding.frames.pop(),
  ],
  ['failed joined measurement', (x) => (event(x, 'candidateJoined').measurement.reason = 'failed')],
  [
    'missing decoded candidate source',
    (x) => {
      const id = qualify(x).attempts[0].measurement.firstFrame + 30;
      x.options.liveIDs = x.options.liveIDs.filter((n) => n !== id);
    },
  ],
  [
    'unregistered baseline revision',
    (x) =>
      x.rawOwned.events
        .filter((e) => e.ownerID === event(x, 'registered').ownerID)
        .forEach((e) => (e.appliedRevision = '1')),
  ],
  [
    'changed baseline configuration',
    (x) => {
      const id = event(x, 'registered').ownerID;
      x.rawOwned.events
        .filter((e) => e.ownerID === id && e.receipt)
        .forEach((e) => (e.receipt.configurationID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'));
    },
  ],
  [
    'changed baseline acceptance time',
    (x) => {
      const id = event(x, 'registered').ownerID;
      x.rawOwned.events
        .filter((e) => e.ownerID === id && ['registered', 'contextCaptured'].includes(e.kind))
        .forEach((e) => (e.receipt.acceptedAt -= 0.01));
    },
  ],
  ['quality overflow', (x) => (x.options.quality.overflow = true)],
  ['quality flags disabled', (x) => (x.options.quality.decoderStallEnabled = false)],
  ['quality foreign timing', (x) => (x.options.quality.timingContract.decoderBudgetMs = 3000)],
  ['quality open terminal', (x) => (x.options.quality.events.at(-1).closed = false)],
  ['quality early terminal', (x) => (x.options.quality.events[2].closed = true)],
  [
    'quality missing baseline application',
    (x) =>
      (x.options.quality.events = x.options.quality.events.filter(
        (e) => !(e.kind === 'applied' && e.revision === '2'),
      )),
  ],
  ['quality revision substitution', (x) => (x.options.quality.events[0].revision = '1')],
  [
    'quality reordered events',
    (x) => (x.options.quality.events[1].at = x.options.quality.events[0].at - 1),
  ],
  ['quality unknown event', (x) => (x.options.quality.events[1].kind = 'invented')],
  [
    'quality unused dictionary row',
    (x) => x.options.quality.evidenceDictionary.thermal.push({ unexpected: 1 }),
  ],
])
  test(`rejects ${label}`, () => {
    const x = fixture();
    mutate(x);
    assert.throws(() => qualify(x));
  });

test('failed or incomplete joined candidates reject explicitly instead of disappearing', () => {
  for (const mutate of [
    (m) => (m.reason = 'failed'),
    (m) => m.encoding.frames.pop(),
    (m) => (m.encoding.outcome = 'cancelled'),
    (m) => (m.encoding.nativeFailure = -1),
    (m) => (m.encoding.acceptedInputCount = 120),
    (m) => (m.encoding.outputCount = 120),
  ]) {
    const x = fixture();
    mutate(event(x, 'candidateJoined').measurement);
    assert.throws(() => qualify(x), /unsupported partial or failed joined candidate/);
  }
});

test('acknowledgements may optionally repeat the actual joined candidate identity', () => {
  const x = fixture();
  for (let i = 0; i < 2; i++)
    event(x, 'acknowledged', i).candidateID = event(
      x,
      'candidateJoined',
      i,
    ).measurement.id.toUpperCase();
  assert.equal(qualify(x).attempts.length, 4);
});

test('candidate cleanup is present and ordered in every original owner', () => {
  const x = fixture();
  event(x, 'candidateRetired').kind = 'failed';
  assert.throws(() => qualify(x), /candidate retirement/);
});

test('quality closure cannot be moved beyond the captured publication', () => {
  const x = fixture();
  x.options.quality.events.at(-1).at = x.options.snapshot.captureDetachedAt + 20;
  assert.throws(() => qualify(x), /quality event clock/);
});

for (const [label, mutate] of [
  [
    'duplicate join',
    (x) => {
      const e = event(x, 'candidateJoined');
      const i = x.rawOwned.events.indexOf(e);
      x.rawOwned.events.splice(i + 1, 0, structuredClone(e));
      x.rawOwned.events.forEach((e, i) => (e.ordinal = String(i + 1)));
    },
  ],
  ['missing start', (x) => (event(x, 'candidateStartRequested').kind = 'failed')],
  [
    'missing native candidate source',
    (x) => {
      const first = qualify(x).attempts[0].measurement.firstFrame;
      const i = x.options.format.compressedFrames.findIndex(
        (f) => fixtureFrameID(f.sourcePTS) === first,
      );
      assert(i >= 0);
      x.options.format.compressedFrames.splice(i, 1);
    },
  ],
  ['foreign media scope', (x) => (x.options.format.scope.matchID = 'foreign')],
  ['native probe corruption', (x) => (event(x, 'allocated').snapshot.publishingGeneration = '2')],
  [
    'raw resource overflow',
    (x) =>
      (event(x, 'candidateJoined').measurement.encoding.frames[0].rawByteCount = 17 * 1024 * 1024),
  ],
  [
    'raw A/V cost corruption',
    (x) => (event(x, 'candidateJoined').measurement.transport.mux.transportBytes += 188),
  ],
  ['quality receipt substitution', (x) => (x.options.quality.events[1].receipt.acceptedAt += 0.01)],
  [
    'quality profile receipt substitution',
    (x) =>
      (x.options.quality.events.find((e) => e.kind === 'applied').profileReceipt.acknowledgedAt +=
        0.01),
  ],
])
  test(`whole history rejects ${label}`, () => {
    const x = fixture();
    mutate(x);
    assert.throws(() => qualify(x));
  });
