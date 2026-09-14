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
for (const value of ['12', '90', '180', '181', '600']) {
  test(`explicit ${value}-second hold uses bounded extended evidence`, () => {
    assert.deepEqual(
      options.nativeStreamingOptions({
        streaming: true,
        environment: {
          SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
          SCOREBUG_TEST_STREAM_HOLD_SECONDS: value,
        },
      }),
      {
        holdSeconds: Number(value),
        completedWindowLimit: Number(value) > 180 ? 128 : 64,
        extended: true,
      },
    );
  });
}
for (const value of ['', ' 90', '90 ', '090', '+90', '9e1', '90.0', '11', '601', '-1', 'NaN']) {
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

test('ten-minute source coverage cannot pass with a shorter saved stream', () => {
  assert.equal(options.qualifyNativeStreamingHold({ holdSeconds: 600, savedFrames: 18000 }), 600);
  assert.throws(
    () => options.qualifyNativeStreamingHold({ holdSeconds: 600, savedFrames: 17999 }),
    /shorter/,
  );
});
test('workflow and XCTest budgets extend only beyond the existing hold bound', () => {
  for (const holdSeconds of [12, 180])
    assert.deepEqual(options.nativeStreamingTestBudget(holdSeconds), {
      workflowTimeoutMs: 600000,
      testExecutionAllowanceSeconds: null,
    });
  assert.deepEqual(options.nativeStreamingTestBudget(181), {
    workflowTimeoutMs: 601000,
    testExecutionAllowanceSeconds: 361,
  });
  assert.deepEqual(options.nativeStreamingTestBudget(600), {
    workflowTimeoutMs: 1020000,
    testExecutionAllowanceSeconds: 780,
  });
  for (const value of [11, 601, Infinity, '600', 600.5])
    assert.throws(() => options.nativeStreamingTestBudget(value), /hold/);
});

test('motion workload is absent by default and requires exact trusted opt-in', () => {
  assert.equal(options.nativeFixtureWorkload({ streaming: false, environment: {} }), 'barcode');
  assert.equal(options.nativeFixtureWorkload({ streaming: true, environment: {} }), 'barcode');
  assert.equal(
    options.nativeFixtureWorkload({
      streaming: true,
      environment: {
        SCOREBUG_TEST_MOTION_FIXTURE: '1',
        SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
      },
    }),
    'motion',
  );
});
for (const flag of ['', '0', 'true', '01', ' 1', '1 ', 1, true, null]) {
  test(`motion workload rejects malformed opt-in ${JSON.stringify(flag)}`, () => {
    assert.throws(
      () =>
        options.nativeFixtureWorkload({
          streaming: true,
          environment: {
            SCOREBUG_TEST_MOTION_FIXTURE: flag,
            SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
          },
        }),
      /motion/i,
    );
  });
}
test('motion workload requires native streaming and direct recorder', () => {
  for (const streaming of [false, true])
    for (const direct of [undefined, 'true', '0', '1']) {
      if (streaming && direct === '1') continue;
      assert.throws(
        () =>
          options.nativeFixtureWorkload({
            streaming,
            environment: {
              SCOREBUG_TEST_MOTION_FIXTURE: '1',
              SCOREBUG_TEST_DIRECT_RTMP_RECORDER: direct,
            },
          }),
        /motion/i,
      );
    }
});
