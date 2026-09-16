import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { recordWorkerProcessingEvidence } from '../worker-processing-qualification.mjs';
const fixture = () =>
  JSON.parse(
    readFileSync(
      new URL('../../packages/protocol/fixtures/worker-processing-v1.json', import.meta.url),
    ),
  ).pending.status;
test('processing collector retains bounded allowlisted copies and updates completion', () => {
  const s = fixture(),
    history = new Map();
  s.secret = 'private';
  s.observation.processing.secret = 'private';
  s.publication.clock.secret = 'private';
  recordWorkerProcessingEvidence(history, s, 1);
  assert(!JSON.stringify([...history.values()]).includes('private'));
  s.observation.processing.interval.completedFrames = 150;
  s.observation.processing.interval.pendingFrames = 0;
  assert.equal([...history.values()][0].processing.interval.completedFrames, 149);
  recordWorkerProcessingEvidence(history, s, 1);
  assert.equal([...history.values()][0].processing.interval.completedFrames, 150);
  delete s.observation.processing;
  recordWorkerProcessingEvidence(history, s, 1);
  assert.equal(history.size, 1); // historical evidence; current omissions are not manufactured samples
});
for (const [label, mutate] of Object.entries({
  game: (s) => (s.gameId = s.observation.gameId = { secret: 'private' }),
  worker: (s) => (s.workerId = { secret: 'private' }),
  generation: (s) => (s.generation = s.observation.generation = -1),
  publication: (s) => (s.publication.readerId = { secret: 'private' }),
  clock: (s) => (s.publication.clock.originPTS = { secret: 'private' }),
  counts: (s) => (s.observation.processing.interval.completedFrames = -1),
  anchor: (s) => (s.observation.processing.interval.sourceStartExclusive = 4000),
  correspondence: (s) => s.observation.decodedVideo.completed.lastPTS++,
  state: (s) => (s.observation.state = 'stopping'),
  timing: (s) => (s.observation.processing.interval.filterDuration.maximumMs = Number.MAX_VALUE),
}))
  test(`collector rejects malformed ${label} without retaining data`, () => {
    const s = fixture(),
      history = new Map();
    mutate(s);
    assert.throws(() => recordWorkerProcessingEvidence(history, s));
    assert.equal(history.size, 0);
  });
