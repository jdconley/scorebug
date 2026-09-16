import assert from 'node:assert/strict';
import test from 'node:test';
import { nativeQualityOptions } from '../native-streaming-options.mjs';
const fixture = () => ({
  environment: {
    SCOREBUG_TEST_NATIVE_QUALITY: '1',
    SCOREBUG_TEST_NATIVE_CONFIRMATION: '1',
    SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
  },
  requireProcessing: true,
  holdSeconds: 90,
});
test('confirmation requires an explicitly enabled native quality fixture', () => {
  assert.deepEqual(nativeQualityOptions(fixture()), {
    requireQuality: true,
    requireConfirmation: true,
  });
  assert.deepEqual(
    nativeQualityOptions({ environment: {}, requireProcessing: false, holdSeconds: 12 }),
    { requireQuality: false, requireConfirmation: false },
  );
  const f = fixture();
  delete f.environment.SCOREBUG_TEST_NATIVE_CONFIRMATION;
  assert.deepEqual(nativeQualityOptions(f), { requireQuality: true, requireConfirmation: false });
});
for (const [name, mutate] of Object.entries({
  missingQuality: (f) => delete f.environment.SCOREBUG_TEST_NATIVE_QUALITY,
  badQuality: (f) => (f.environment.SCOREBUG_TEST_NATIVE_QUALITY = 'true'),
  badConfirmation: (f) => (f.environment.SCOREBUG_TEST_NATIVE_CONFIRMATION = '0'),
  missingRecorder: (f) => delete f.environment.SCOREBUG_TEST_DIRECT_RTMP_RECORDER,
  missingProcessing: (f) => (f.requireProcessing = false),
  shortHold: (f) => (f.holdSeconds = 89),
}))
  test(`rejects invalid quality confirmation setup: ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => nativeQualityOptions(f));
  });
