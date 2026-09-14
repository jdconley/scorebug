import assert from 'node:assert/strict';
import { test } from 'node:test';
import { recordDecodedVideoEvidence } from '../native-streaming-fixture.mjs';

test('qualification rejects later invalidation of an already observed window in any worker state', () => {
  for (const state of ['producing_output', 'retrying', 'stale']) {
    const windows = new Map();
    const status = {
      gameId: 'game',
      generation: 1,
      workerId: 'worker',
      state: 'producing_output',
      observation: {
        gameId: 'game',
        generation: 1,
        attempt: 1,
        decodedVideo: {
          completed: {
            sequence: 1,
            durationMs: 5000,
            ageMs: 0,
            firstPTS: 0,
            lastPTS: 447000,
            freshFrames: 150,
            duplicateFrames: 0,
            reorderedFrames: 0,
            valid: true,
          },
          invalidReason: null,
          ended: false,
        },
      },
    };
    recordDecodedVideoEvidence(windows, status);
    assert.equal(windows.size, 1);
    status.state = state;
    status.observation.decodedVideo.invalidReason = 'framing';
    status.observation.decodedVideo.completed.valid = false;
    assert.throws(() => recordDecodedVideoEvidence(windows, status), /invalid decoder telemetry/);
  }
});

test('qualification rejects invalid telemetry before a first completed window', () => {
  assert.throws(
    () =>
      recordDecodedVideoEvidence(new Map(), {
        state: 'starting',
        observation: {
          generation: 1,
          attempt: 1,
          decodedVideo: { completed: null, invalidReason: 'ordinal', ended: false },
        },
      }),
    /invalid decoder telemetry/,
  );
});

function usableStatus(sequence) {
  return {
    gameId: 'game',
    generation: 1,
    workerId: 'worker',
    state: 'producing_output',
    observation: {
      gameId: 'game',
      generation: 1,
      attempt: 1,
      decodedVideo: {
        ended: false,
        invalidReason: null,
        completed: {
          sequence,
          durationMs: 5000,
          ageMs: 0,
          firstPTS: (sequence - 1) * 450000,
          lastPTS: sequence * 450000 - 3000,
          freshFrames: 150,
          duplicateFrames: 0,
          reorderedFrames: 0,
          valid: true,
        },
      },
    },
  };
}
test('decoded history retains its default bound and supports a bounded ten-minute fixture', () => {
  for (const limit of [64, 128]) {
    const windows = new Map();
    for (let i = 1; i <= limit; i++) recordDecodedVideoEvidence(windows, usableStatus(i), limit);
    assert.equal(windows.size, limit);
    assert.throws(
      () => recordDecodedVideoEvidence(windows, usableStatus(limit + 1), limit),
      /bound/,
    );
    const changed = usableStatus(limit);
    changed.observation.decodedVideo.completed.freshFrames = 149;
    assert.throws(() => recordDecodedVideoEvidence(windows, changed, limit), /immutable/);
    const invalid = usableStatus(limit);
    invalid.observation.decodedVideo.invalidReason = 'framing';
    assert.throws(() => recordDecodedVideoEvidence(windows, invalid, limit), /invalid decoder/);
  }
  const defaults = new Map();
  for (let i = 1; i <= 64; i++) recordDecodedVideoEvidence(defaults, usableStatus(i));
  assert.throws(() => recordDecodedVideoEvidence(defaults, usableStatus(65)), /bound/);
  for (const limit of [0, 65, 129, Infinity, '128'])
    assert.throws(() => recordDecodedVideoEvidence(new Map(), usableStatus(1), limit), /bound/);
});
