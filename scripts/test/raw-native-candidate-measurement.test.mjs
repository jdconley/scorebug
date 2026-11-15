import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { gunzipSync } from 'node:zlib';
import * as implementation from '../native-candidate-measurement.mjs';
import { fixtureFrameID } from '../video-observation-qualification.mjs';

const provenance = JSON.parse(
  readFileSync(new URL('./fixtures/owned-candidate-mAluZi.provenance.json', import.meta.url)),
);
const compressed = readFileSync(
  new URL('./fixtures/owned-candidate-mAluZi.json.gz', import.meta.url),
);
assert.equal(compressed.length, provenance.compressedBytes);
assert(compressed.length < 64 * 1024);
const bytes = gunzipSync(compressed, { maxOutputLength: 1024 * 1024 });
assert.equal(bytes.length, provenance.bytes);
assert.equal(createHash('sha256').update(bytes).digest('hex'), provenance.sha256);
const audit = JSON.parse(bytes);
assert.equal(audit.events.length, 514);
const resourceLimits = {
  // Pinned SDK contract, not counters manufactured from an owned event.
  rawQueueCount: 4,
  unresolvedInputCount: 16,
  unresolvedRawBytes: 64 * 1024 * 1024,
  rawBytesPerInput: 16 * 1024 * 1024,
};
function fixture(index = 0) {
  const p = provenance.cases[index];
  const event = audit.events[Number(p.measurementEventOrdinal) - 1];
  const start = audit.events[Number(p.startEventOrdinal) - 1];
  const transferred = audit.events[Number(p.transferEventOrdinal) - 1];
  const registered = audit.events.find((e) => e.ownerID === p.ownerID && e.kind === 'registered');
  assert.equal(event.kind, 'candidateJoined');
  assert.equal(start.kind, 'candidateStartRequested');
  assert.equal(transferred.kind, 'applicationTransferred');
  for (const e of [event, start, transferred, registered]) {
    assert.equal(e.ownerID, p.ownerID);
    assert.equal(e.appliedRevision, p.appliedRevision);
  }
  return structuredClone({
    measurement: event.measurement,
    expected: {
      scope: audit.scope,
      profile: registered.targetProfile,
      liveProfile: registered.baselineProfile,
      publishingGeneration: registered.receipt.publishingGeneration,
      measurementID: transferred.candidateID,
      baselineEncoderSessionID: registered.receipt.encoderSessionID,
      startedNotBefore: start.at,
      endedNotAfter: event.at,
      baselineFirstFrame: fixtureFrameID(p.baselineFirstSourcePTS),
      baselineLastFrame: fixtureFrameID(p.baselineLastSourcePTS),
      resourceLimits,
    },
  });
}
function qualify({ measurement, expected }) {
  assert.equal(typeof implementation.qualifyRawNativeCandidateMeasurement, 'function');
  return implementation.qualifyRawNativeCandidateMeasurement(measurement, expected);
}
for (const index of [0, 1])
  test(`original owned candidate ${index + 1} replays raw resources and A/V cost without an envelope`, () => {
    const input = fixture(index),
      before = structuredClone(input);
    assert.equal(input.measurement.formatVersion, undefined);
    assert.equal(input.measurement.resourceLimits, undefined);
    const result = qualify(input);
    assert.equal(result.frames, 121);
    assert.equal(result.sourceDuration, 4);
    assert.equal(result.maximumUnresolvedInputs, 14);
    assert.equal(result.maximumUnresolvedRawBytes, 14 * 3114720);
    assert.equal(result.transport.transportBytes, provenance.cases[index].transportBytes);
    assert.equal(
      result.transport.transportMessageCount,
      provenance.cases[index].transportMessageCount,
    );
    assert.deepEqual(
      Object.keys(result).sort(),
      [
        'transport',
        'maximumUnresolvedInputs',
        'maximumUnresolvedRawBytes',
        'profile',
        'liveProfile',
        'scope',
        'id',
        'encoderSessionID',
        'frames',
        'firstFrame',
        'lastFrame',
        'sourceDuration',
        'sourceFPS',
        'submissionDuration',
        'bytes',
        'maximumFrameBytes',
        'maximumLatency',
        'payloadBitsPerSecond',
      ].sort(),
    );
    assert.deepEqual(input, before);
  });

const otherID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
for (const [label, mutate] of [
  ['missing frame', (m) => m.encoding.frames.pop()],
  ['frame identity', (m) => (m.encoding.frames[1].sourcePTS = m.encoding.frames[0].sourcePTS)],
  ['frame bytes', (m) => m.encoding.frames[3].byteCount++],
  ['initial sync frame', (m) => (m.encoding.frames[0].isSync = false)],
  ['missing raw bytes', (m) => delete m.encoding.frames[0].rawByteCount],
  ['oversize raw frame', (m) => (m.encoding.frames[0].rawByteCount = 16 * 1024 * 1024 + 1)],
  [
    'aggregate raw bytes',
    (m) => m.encoding.frames.forEach((f) => (f.rawByteCount = 8 * 1024 * 1024)),
  ],
  ['missing admission time', (m) => delete m.encoding.frames[0].admittedAt],
  [
    'admission after submission',
    (m) => (m.encoding.frames[0].admittedAt = m.encoding.frames[0].submittedAt + 0.01),
  ],
  [
    'completion before submission',
    (m) => (m.encoding.frames[0].completedAt = m.encoding.frames[0].submittedAt - 0.01),
  ],
  ['foreign frame session', (m) => (m.encoding.frames[1].encoderSessionID = otherID)],
  ['foreign measurement identity', (m) => (m.id = otherID)],
  ['missing scope', (m) => delete m.scope],
  ['foreign profile', (m) => (m.profile = '540p30')],
  ['failed encoding', (m) => (m.encoding.nativeFailure = -1)],
  ['missing transport', (m) => delete m.transport],
  ['foreign transport generation', (m) => (m.transport.publishingGeneration = '2')],
  ['missing audio', (m) => (m.transport.audio = [])],
  ['missing audio boundary', (m) => delete m.transport.followingAudio],
  ['audio bytes', (m) => m.transport.audio[0].byteCount++],
  ['missing mux input', (m) => m.transport.mux.inputs.pop()],
  ['mux cost', (m) => (m.transport.mux.transportBytes += 188)],
])
  test(`raw owned candidate rejects ${label}`, () => {
    for (const index of [0, 1]) {
      const input = fixture(index);
      mutate(input.measurement);
      assert.throws(() => qualify(input));
    }
  });

test('raw candidate requires every explicit expected binding and unchanged resource contract', () => {
  for (const key of Object.keys(fixture().expected)) {
    const input = fixture();
    delete input.expected[key];
    assert.throws(() => qualify(input), key);
  }
  for (const key of Object.keys(resourceLimits)) {
    const input = fixture();
    input.expected.resourceLimits[key]++;
    assert.throws(() => qualify(input), key);
  }
  for (const [key, value] of Object.entries({
    measurementID: otherID,
    publishingGeneration: '2',
    baselineEncoderSessionID: 'not-a-session',
    startedNotBefore: Infinity,
    endedNotAfter: NaN,
    baselineFirstFrame: -1,
    baselineLastFrame: 65536,
    skipTransport: true,
  })) {
    const input = fixture();
    input.expected[key] = value;
    assert.throws(() => qualify(input), key);
  }
});

test('raw candidate is contained in actual start/join and baseline source bounds', () => {
  for (const index of [0, 1]) {
    for (const mutate of [
      (x) => (x.expected.startedNotBefore = x.measurement.startedAt + 0.001),
      (x) => (x.expected.endedNotAfter = x.measurement.endedAt - 0.001),
      (x) => (x.expected.baselineFirstFrame = fixtureFrameID(x.measurement.firstInputPTS) + 1),
      (x) => (x.expected.baselineLastFrame = fixtureFrameID(x.measurement.lastInputPTS) - 1),
      (x) =>
        (x.expected.baselineEncoderSessionID =
          x.measurement.encoding.encoderSessionID.toLowerCase()),
    ]) {
      const input = fixture(index);
      mutate(input);
      assert.throws(() => qualify(input));
    }
  }
});
