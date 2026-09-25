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

test('reconnecting capacity diagnostics cannot be selected on a normal fixture', async () => {
  let calls = 0;
  await assert.rejects(
    () =>
      nativeStreamingFixture({
        capacityDiagnostics: true,
        run: async () => {
          calls++;
          throw Error('resource setup');
        },
      }),
    /Capacity diagnostics require/,
  );
  assert.equal(calls, 0);
});

test('complete750k diagnostic worker route reaches resource setup', async (t) => {
  const artifact = await mkdtemp(join(tmpdir(), 'capacity750-fixture-'));
  t.after(() => rm(artifact, { recursive: true, force: true }));
  recorderEnvironment(t);
  const calls = [];
  await assert.rejects(() =>
    nativeStreamingFixture({
      ...options(),
      capacityDiagnostics: true,
      uplinkProfile: 'capacity750k',
      artifact,
      run: async (...args) => {
        calls.push(args);
        throw Error('Stop before resource creation');
      },
    }),
  );
  assert.equal(calls.length, 1);
  assert.equal(calls[0][2], 'publication-relay-image');
});

for (const policy of ['congestion-v1', 'rate-ledger-v1', 'token-budget-v1'])
  test(`capacity evidence ${policy} reaches resource setup on its complete route`, async (t) => {
    recorderEnvironment(t);
    const artifact = await mkdtemp(join(tmpdir(), 'capacity-policy-fixture-'));
    t.after(() => rm(artifact, { recursive: true, force: true }));
    const calls = [];
    await assert.rejects(
      nativeStreamingFixture({
        ...options(),
        artifact,
        capacityEvidencePolicy: policy,
        run: async (...args) => {
          calls.push(args);
          throw Error('Stop before resources');
        },
      }),
    );
    assert.equal(calls.length, 1);
    assert.equal(calls[0][2], 'publication-relay-image');
  });

for (const policy of ['unknown', null, '', 1])
  test(`invalid capacity evidence ${JSON.stringify(policy)} fails before resource setup`, async (t) => {
    recorderEnvironment(t);
    let calls = 0;
    await assert.rejects(
      nativeStreamingFixture({
        ...options(),
        capacityEvidencePolicy: policy,
        run: async () => {
          calls++;
          throw Error('Unexpected resource setup');
        },
      }),
      /capacity evidence policy/i,
    );
    assert.equal(calls, 0);
  });

test('rate ledger evidence cannot be selected outside capacity recovery', async () => {
  let calls = 0;
  await assert.rejects(
    nativeStreamingFixture({
      capacityEvidencePolicy: 'rate-ledger-v1',
      run: async () => {
        calls++;
        throw Error('Unexpected resource setup');
      },
    }),
    /rate ledger evidence requires capacity recovery/i,
  );
  assert.equal(calls, 0);
});

for (const latency of [400, 700, 1000])
  test(`owned retry diagnostic${latency}ms route reaches resource setup`, async (t) => {
    recorderEnvironment(t);
    const artifact = await mkdtemp(join(tmpdir(), 'owned-retry-latency-'));
    t.after(() => rm(artifact, { recursive: true, force: true }));
    const calls = [];
    await assert.rejects(
      nativeStreamingFixture({
        ...options(),
        artifact,
        capacityDiagnostics: true,
        uplinkProfile: 'capacity750k-retry',
        capacityEvidencePolicy: 'token-budget-v1',
        publishPeerLatencyMs: latency,
        run: async (...args) => {
          calls.push(args);
          throw Error('Stop before resource creation');
        },
      }),
    );
    assert.equal(calls.length, 1);
    assert.equal(calls[0][2], 'publication-relay-image');
  });

for (const latency of [700, 1000])
  for (const patch of [
    { capacityDiagnostics: false },
    { uplinkProfile: 'capacity550k' },
    { uplinkProfile: 'capacity750k' },
    { capacityEvidencePolicy: 'congestion-v1' },
    { capacityEvidencePolicy: 'rate-ledger-v1' },
    { publishPeerLatencyMs: String(latency) },
    { publishPeerLatencyMs: latency + 1 },
    { measuredTrial: false },
    { collectCapacityClock: undefined },
  ])
    test(`${latency}ms retry worker rejects incompatible route before resources${JSON.stringify(patch)}`, async (t) => {
      recorderEnvironment(t);
      let calls = 0;
      await assert.rejects(
        nativeStreamingFixture({
          ...options(),
          capacityDiagnostics: true,
          uplinkProfile: 'capacity750k-retry',
          capacityEvidencePolicy: 'token-budget-v1',
          publishPeerLatencyMs: latency,
          ...patch,
          run: async () => {
            calls++;
            throw Error('Unexpected resource setup');
          },
        }),
        /complete exclusive route/,
      );
      assert.equal(calls, 0);
    });
