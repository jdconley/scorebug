import assert from 'node:assert/strict';
export function nativeLiveProfile({
  environment,
  streaming,
  requireProcessing,
  requirePublication,
  holdSeconds,
}) {
  const raw = environment.SCOREBUG_TEST_LIVE_PROFILE;
  if (raw === undefined) return '1080p30';
  assert.ok(
    raw === '540p30' &&
      streaming &&
      requireProcessing &&
      requirePublication &&
      Number.isInteger(holdSeconds) &&
      holdSeconds >= 90 &&
      holdSeconds <= 600 &&
      environment.SCOREBUG_TEST_DIRECT_RTMP_RECORDER === '1' &&
      environment.SCOREBUG_TEST_MOTION_FIXTURE === 'blocks16' &&
      environment.SCOREBUG_TEST_NATIVE_QUALITY === undefined &&
      environment.SCOREBUG_TEST_NATIVE_CONFIRMATION === undefined,
    'Reduced live profile requires explicit fixed540p structured-motion qualification',
  );
  return raw;
}
export function nativeMediaGeometry(profile, live) {
  assert.ok(['1080p30', '540p30'].includes(profile));
  const scale = live && profile === '540p30' ? 0.5 : 1;
  return {
    width: 1920 * scale,
    height: 1080 * scale,
    barcodeY: 20 * scale,
    overlay: { width: 750 * scale, height: 120 * scale, y: 930 * scale },
  };
}
