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
    ['540p30', '360p30', '240p30'].includes(raw) &&
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
    'Reduced live profile requires explicit fixed-profile structured-motion qualification',
  );
  return raw;
}
export function nativeMediaGeometry(profile, live) {
  assert.ok(['1080p30', '540p30', '360p30', '240p30'].includes(profile));
  const [width, height] =
    !live || profile === '1080p30'
      ? [1920, 1080]
      : profile === '540p30'
        ? [960, 540]
        : profile === '360p30'
          ? [640, 360]
          : [426, 240];
  // 426x240 is not an exact uniform scale of 1920x1080. Keep every crop
  // coordinate integral and use the actual horizontal and vertical scales.
  const scaleX = width / 1920,
    scaleY = height / 1080;
  return {
    width,
    height,
    barcodeY: Math.floor(20 * scaleY),
    overlay: {
      width: Math.floor(750 * scaleX),
      height: Math.floor(120 * scaleY),
      y: Math.floor(930 * scaleY),
    },
  };
}
