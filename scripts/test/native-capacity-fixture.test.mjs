import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { nativeStreamingFixture } from '../native-streaming-fixture.mjs';
const options = () => ({
  capacityRecovery: true,
  uplinkProfile: 'capacity550k',
  measuredTrial: true,
  requirePublication: true,
  requireReceiverProbe: true,
  stagedReceiverProbe: true,
  candidateHeadroom: true,
  liveProfile: '240p30',
  workerOutputProfile: '360p30',
  publishPeerLatencyMs: 400,
  collectCapacityClock: async () => {},
});
function recorderEnvironment(t) {
  const prior = process.env.SCOREBUG_TEST_DIRECT_RTMP_RECORDER;
  process.env.SCOREBUG_TEST_DIRECT_RTMP_RECORDER = '1';
  t.after(() => {
    if (prior === undefined) delete process.env.SCOREBUG_TEST_DIRECT_RTMP_RECORDER;
    else process.env.SCOREBUG_TEST_DIRECT_RTMP_RECORDER = prior;
  });
}
test('complete capacity worker route reaches resource setup without using a decoder fault', async (t) => {
  const artifact = await mkdtemp(join(tmpdir(), 'capacity-fixture-'));
  t.after(() => rm(artifact, { recursive: true, force: true }));
  recorderEnvironment(t);
  const calls = [];
  await assert.rejects(
    nativeStreamingFixture({
      ...options(),
      artifact,
      run: async (...args) => {
        calls.push(args);
        throw Error('Deliberately stop before any resource creation');
      },
    }),
  );
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], 'docker');
  assert.equal(calls[0][2], 'publication-relay-image');
});
for (const [name, value] of Object.entries({
  capacityRecovery: false,
  uplinkProfile: 'loss0p2-delay30',
  measuredTrial: false,
  measuredRecovery: true,
  repeatedRecovery: true,
  requirePublication: false,
  requireReceiverProbe: false,
  stagedReceiverProbe: false,
  candidateHeadroom: false,
  liveProfile: '360p30',
  workerOutputProfile: '240p30',
  publishPeerLatencyMs: 399,
  collectCapacityClock: undefined,
  decoderStall: true,
  deadlineResets: true,
  cadenceReports: true,
  publishPacing: 'relative',
}))
  test(`capacity worker rejects incompatible ${name} before resource setup`, async (t) => {
    recorderEnvironment(t);
    let calls = 0;
    await assert.rejects(
      nativeStreamingFixture({
        ...options(),
        [name]: value,
        run: async () => {
          calls++;
          throw Error('Unexpected resource setup');
        },
      }),
    );
    assert.equal(calls, 0);
  });
