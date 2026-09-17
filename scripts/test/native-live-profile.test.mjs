import test from 'node:test';
import assert from 'node:assert/strict';
import { nativeLiveProfile, nativeMediaGeometry } from '../native-live-profile.mjs';
const environment = {
  SCOREBUG_TEST_LIVE_PROFILE: '540p30',
  SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
  SCOREBUG_TEST_MOTION_FIXTURE: 'blocks16',
};
const args = {
  environment,
  streaming: true,
  requireProcessing: true,
  requirePublication: true,
  holdSeconds: 90,
};
test('fixed reduced live profile is explicit and rejects missing evidence or adaptive flags', () => {
  assert.equal(nativeLiveProfile({ ...args, environment: {} }), '1080p30');
  assert.equal(nativeLiveProfile(args), '540p30');
  for (const change of [
    { streaming: false },
    { requireProcessing: false },
    { requirePublication: false },
    { holdSeconds: 89 },
    { holdSeconds: 601 },
  ])
    assert.throws(() => nativeLiveProfile({ ...args, ...change }));
  for (const [key, values] of Object.entries({
    SCOREBUG_TEST_LIVE_PROFILE: ['', '1080p30', '540', '540p30 ', null],
    SCOREBUG_TEST_DIRECT_RTMP_RECORDER: [undefined, 'true'],
    SCOREBUG_TEST_MOTION_FIXTURE: [undefined, '1'],
    SCOREBUG_TEST_NATIVE_QUALITY: ['1', '0'],
    SCOREBUG_TEST_NATIVE_CONFIRMATION: ['1', '0'],
  }))
    for (const value of values)
      assert.throws(() =>
        nativeLiveProfile({ ...args, environment: { ...environment, [key]: value } }),
      );
});
test('live dimensions and sample coordinates cannot lower archive dimensions', () => {
  assert.deepEqual(nativeMediaGeometry('540p30', false), nativeMediaGeometry('1080p30', false));
  assert.deepEqual(nativeMediaGeometry('540p30', true), {
    width: 960,
    height: 540,
    barcodeY: 10,
    overlay: { width: 375, height: 60, y: 465 },
  });
  assert.deepEqual(nativeMediaGeometry('1080p30', true), {
    width: 1920,
    height: 1080,
    barcodeY: 20,
    overlay: { width: 750, height: 120, y: 930 },
  });
  for (const profile of [null, '720p30', 'invalid'])
    assert.throws(() => nativeMediaGeometry(profile, true));
});

test('fixed540 proxy authorization does not weaken adaptive profile prerequisites', async () => {
  const { nativeUplinkOptions } = await import('../native-streaming-options.mjs');
  const input = {
    environment: { ...environment, SCOREBUG_TEST_UPLINK_PROFILE: 'passthrough' },
    streaming: true,
    requireQuality: false,
    requireConfirmation: false,
    requireProcessing: true,
    requirePublication: true,
    fixtureWorkload: 'motion-blocks16',
    holdSeconds: 90,
    liveProfile: '540p30',
  };
  assert.equal(nativeUplinkOptions(input), 'passthrough');
  for (const patch of [
    { liveProfile: '1080p30' },
    { requireQuality: true },
    { requireConfirmation: true },
    { requireProcessing: false },
    { requirePublication: false },
    { fixtureWorkload: 'barcode' },
    { holdSeconds: 89 },
  ])
    assert.throws(() => nativeUplinkOptions({ ...input, ...patch }));
  assert.throws(() =>
    nativeUplinkOptions({
      ...input,
      environment: { ...input.environment, SCOREBUG_TEST_UPLINK_PROFILE: 'rate4m' },
    }),
  );
  assert.equal(
    nativeUplinkOptions({
      ...input,
      holdSeconds: 180,
      environment: { ...input.environment, SCOREBUG_TEST_UPLINK_PROFILE: 'rate4m' },
    }),
    'rate4m',
  );
});

test('fixed360 retains full fixture gates, archive geometry and exclusive route', async () => {
  const env = { ...environment, SCOREBUG_TEST_LIVE_PROFILE: '360p30' };
  assert.equal(nativeLiveProfile({ ...args, environment: env }), '360p30');
  assert.deepEqual(nativeMediaGeometry('360p30', false), nativeMediaGeometry('1080p30', false));
  assert.deepEqual(nativeMediaGeometry('360p30', true), {
    width: 640,
    height: 360,
    barcodeY: 6,
    overlay: { width: 250, height: 40, y: 310 },
  });
  for (const patch of [{ requireProcessing: false }, { holdSeconds: 89 }, { streaming: false }])
    assert.throws(() => nativeLiveProfile({ ...args, ...patch, environment: env }));
  const { nativeUplinkOptions } = await import('../native-streaming-options.mjs');
  const input = {
    ...args,
    environment: { ...env, SCOREBUG_TEST_UPLINK_PROFILE: 'rate4m' },
    holdSeconds: 180,
    liveProfile: '360p30',
    requireQuality: false,
    requireConfirmation: false,
    fixtureWorkload: 'motion-blocks16',
  };
  assert.equal(nativeUplinkOptions(input), 'rate4m');
  for (const patch of [
    { liveProfile: '540p30' },
    { requireQuality: true },
    { requirePublication: false },
  ])
    assert.throws(() => nativeUplinkOptions({ ...input, ...patch }));
});

test('fixed240 uses actual even geometry and preserves archive and admission gates', async () => {
  const env = { ...environment, SCOREBUG_TEST_LIVE_PROFILE: '240p30' };
  assert.equal(nativeLiveProfile({ ...args, environment: env }), '240p30');
  assert.deepEqual(nativeMediaGeometry('240p30', false), nativeMediaGeometry('1080p30', false));
  assert.deepEqual(nativeMediaGeometry('240p30', true), {
    width: 426,
    height: 240,
    barcodeY: 4,
    overlay: { width: 166, height: 26, y: 206 },
  });
  for (const patch of [{ holdSeconds: 89 }, { streaming: false }, { requireProcessing: false }])
    assert.throws(() => nativeLiveProfile({ ...args, ...patch, environment: env }));
  for (const key of ['SCOREBUG_TEST_DIRECT_RTMP_RECORDER', 'SCOREBUG_TEST_MOTION_FIXTURE']) {
    const invalid = { ...env };
    delete invalid[key];
    assert.throws(() => nativeLiveProfile({ ...args, environment: invalid }));
  }
  const { nativeUplinkOptions } = await import('../native-streaming-options.mjs');
  const input = {
    ...args,
    environment: { ...env, SCOREBUG_TEST_UPLINK_PROFILE: 'rate4m' },
    holdSeconds: 180,
    liveProfile: '240p30',
    requireQuality: false,
    requireConfirmation: false,
    fixtureWorkload: 'motion-blocks16',
  };
  assert.equal(nativeUplinkOptions(input), 'rate4m');
  for (const patch of [
    { liveProfile: '360p30' },
    { requireQuality: true },
    { requirePublication: false },
  ])
    assert.throws(() => nativeUplinkOptions({ ...input, ...patch }));
});
