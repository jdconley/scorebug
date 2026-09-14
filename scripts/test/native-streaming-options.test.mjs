import assert from 'node:assert/strict';
import test from 'node:test';
import * as options from '../native-streaming-options.mjs';

test('short native run retains its existing hold and history', () => {
  assert.deepEqual(options.nativeStreamingOptions({ streaming: true, environment: {} }), {
    holdSeconds: 12,
    completedWindowLimit: 8,
    extended: false,
  });
});

test('saved source coverage must include the complete requested hold', () => {
  assert.equal(options.qualifyNativeStreamingHold({ holdSeconds: 180, savedFrames: 5400 }), 180);
  assert.throws(
    () => options.qualifyNativeStreamingHold({ holdSeconds: 180, savedFrames: 5399 }),
    /shorter/,
  );
  for (const savedFrames of [0, NaN, Infinity, '5400', 5400.5])
    assert.throws(
      () => options.qualifyNativeStreamingHold({ holdSeconds: 180, savedFrames }),
      /frame/,
    );
});
for (const value of ['12', '90', '180']) {
  test(`explicit ${value}-second hold uses bounded extended evidence`, () => {
    assert.deepEqual(
      options.nativeStreamingOptions({
        streaming: true,
        environment: {
          SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
          SCOREBUG_TEST_STREAM_HOLD_SECONDS: value,
        },
      }),
      { holdSeconds: Number(value), completedWindowLimit: 64, extended: true },
    );
  });
}
for (const value of ['', ' 90', '90 ', '090', '+90', '9e1', '90.0', '11', '181', '-1', 'NaN']) {
  test(`rejects malformed or unbounded hold ${JSON.stringify(value)}`, () => {
    assert.throws(
      () =>
        options.nativeStreamingOptions({
          streaming: true,
          environment: {
            SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
            SCOREBUG_TEST_STREAM_HOLD_SECONDS: value,
          },
        }),
      /hold/i,
    );
  });
}
test('extended hold requires streaming and exact direct recorder selection', () => {
  for (const streaming of [false, true])
    for (const flag of [undefined, 'true', '0', '1']) {
      if (streaming && flag === '1') continue;
      assert.throws(
        () =>
          options.nativeStreamingOptions({
            streaming,
            environment: {
              SCOREBUG_TEST_DIRECT_RTMP_RECORDER: flag,
              SCOREBUG_TEST_STREAM_HOLD_SECONDS: '180',
            },
          }),
        /requires/i,
      );
    }
});
