import assert from 'node:assert/strict';
import { test } from 'node:test';
import { qualifyPublishingClockObservation } from '../publishing-clock-qualification.mjs';

const scope = {
  recordingID: 'recording-1',
  matchID: 'match-1',
  broadcastGeneration: 3,
  publishingAttemptID: '11C44B00-6074-471A-AFC7-226BB001A4C8',
  appliedProfileRevision: '1',
};
const fixture = () => ({
  scope: structuredClone(scope),
  isClosed: true,
  publishingClockObservation: {
    scope: structuredClone(scope),
    isClosed: true,
    publishingGeneration: '18446744073709551615',
    sourceOrigin: { value: '9007199254740993', timescale: 1000000000, epoch: '0', flags: 1 },
    timescale: 90000,
    presentationLead: '9000',
    wireModulus: '8589934592',
  },
});
const qualify = (snapshot) => qualifyPublishingClockObservation({ snapshot, expectedScope: scope });

test('qualifies closed app-scoped exact clock without inventing the muxer origin from capture', () => {
  const snapshot = fixture();
  const result = qualify(snapshot);
  assert.deepEqual(result, snapshot.publishingClockObservation);
  snapshot.publishingClockObservation.sourceOrigin.value = '0';
  snapshot.publishingClockObservation.scope.recordingID = 'changed';
  assert.equal(result.sourceOrigin.value, '9007199254740993');
  assert.equal(result.scope.recordingID, scope.recordingID);
});
for (const key of Object.keys(scope)) {
  test(`rejects cross-attempt clock scope ${key}`, () => {
    const snapshot = fixture();
    snapshot.publishingClockObservation.scope[key] = key === 'broadcastGeneration' ? 4 : 'other';
    assert.throws(() => qualify(snapshot));
  });
  test(`rejects crossed enclosing scope ${key}`, () => {
    const snapshot = fixture();
    snapshot.scope[key] = key === 'broadcastGeneration' ? 4 : 'other';
    assert.throws(() => qualify(snapshot));
  });
}
for (const [name, mutate] of [
  [
    'missing clock',
    (s) => {
      delete s.publishingClockObservation;
    },
  ],
  [
    'unavailable clock',
    (s) => {
      s.publishingClockObservation = null;
    },
  ],
  [
    'open clock',
    (s) => {
      s.publishingClockObservation.isClosed = false;
    },
  ],
  [
    'open enclosing observation',
    (s) => {
      s.isClosed = false;
    },
  ],
  [
    'missing closure',
    (s) => {
      delete s.publishingClockObservation.isClosed;
    },
  ],
  [
    'zero native generation',
    (s) => {
      s.publishingClockObservation.publishingGeneration = '0';
    },
  ],
  [
    'lossy source origin',
    (s) => {
      s.publishingClockObservation.sourceOrigin.value = 9007199254740992;
    },
  ],
  [
    'noncanonical origin',
    (s) => {
      s.publishingClockObservation.sourceOrigin.value = '-0';
    },
  ],
  [
    'invalid epoch',
    (s) => {
      s.publishingClockObservation.sourceOrigin.epoch = '1';
    },
  ],
  [
    'invalid flags',
    (s) => {
      s.publishingClockObservation.sourceOrigin.flags = 5;
    },
  ],
  [
    'wrong projection',
    (s) => {
      s.publishingClockObservation.presentationLead = '0';
    },
  ],
  [
    'unexpected payload',
    (s) => {
      s.publishingClockObservation.media = 'unexpected';
    },
  ],
  [
    'unexpected origin payload',
    (s) => {
      s.publishingClockObservation.sourceOrigin.media = 'unexpected';
    },
  ],
  ['missing expected scope', (s) => {}],
]) {
  test(`rejects ${name}`, () => {
    const snapshot = fixture();
    mutate(snapshot);
    assert.throws(() =>
      name === 'missing expected scope'
        ? qualifyPublishingClockObservation({ snapshot })
        : qualify(snapshot),
    );
  });
}
