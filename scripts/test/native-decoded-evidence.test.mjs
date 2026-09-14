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
