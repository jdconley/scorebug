import assert from 'node:assert/strict';
import test from 'node:test';
import { inspectFrameCodeSamples } from '../impaired-media-diagnostics.mjs';

const samples = (ids) =>
  Buffer.from(
    ids.flatMap((id) => Array.from({ length: 16 }, (_, bit) => (id & (1 << bit) ? 255 : 0))),
  );

test('damaged identities retain the count of decoded frames', () => {
  const bytes = samples([0, 1, 2]);
  bytes[16] = 128;
  const result = inspectFrameCodeSamples(bytes, [0, 1 / 30, 2 / 30]);
  assert.equal(result.decodedFrames, 3);
  assert.equal(result.validSourceIDs, false);
  assert.match(result.sourceIdentityError, /Ambiguous/);
  assert.equal(result.freshFrames, null);
  assert.equal(result.freshFps, null);
  assert.equal(result.sourceFrameLoss, null);
  assert.equal(result.firstSourceFrame, null);
});

test('valid identities and timestamps permit diagnostic measurements', () => {
  const result = inspectFrameCodeSamples(samples([3, 4, 6]), [0, 1 / 30, 2 / 30]);
  assert.equal(result.decodedFrames, 3);
  assert.equal(result.validSourceIDs, true);
  assert.equal(result.freshFrames, 3);
  assert.equal(result.freshFps, 30);
  assert.equal(result.sourceFrameLoss, 0.25);
  assert.equal(result.firstSourceFrame, 3);
  assert.equal(result.lastSourceFrame, 6);
});

test('empty and unavailable samples never claim valid identities', () => {
  for (const bytes of [null, Buffer.alloc(0)]) {
    const result = inspectFrameCodeSamples(bytes, []);
    assert.equal(result.decodedFrames, bytes === null ? null : 0);
    assert.equal(result.validSourceIDs, false);
    assert.equal(result.freshFrames, null);
  }
});

test('truncated, regressed, and out-of-fixture identities stay unqualified', () => {
  for (const bytes of [Buffer.alloc(17), samples([3, 2]), samples([420])]) {
    const result = inspectFrameCodeSamples(bytes, []);
    assert.equal(result.decodedFrames, Math.floor(bytes.length / 16));
    assert.equal(result.validSourceIDs, false);
    assert.equal(result.freshFrames, null);
    assert.ok(result.sourceIdentityError);
  }
});

test('bad or mismatched timestamps cannot produce a fresh frame rate', () => {
  for (const times of [[], [0], [0, NaN], [1, 0], [0, 0]]) {
    const result = inspectFrameCodeSamples(samples([0, 1]), times);
    assert.equal(result.freshFrames, 2);
    assert.equal(result.freshFps, null);
  }
});
