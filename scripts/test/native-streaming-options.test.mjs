import assert from 'node:assert/strict';
import test from 'node:test';
import * as options from '../native-streaming-options.mjs';

test('measured trials receive the same fresh worker report cadence as quality qualification', () => {
  assert.equal(options.fixtureWorkerReportInterval({ environment: {} }), 1000);
  assert.equal(
    options.fixtureWorkerReportInterval({ environment: { SCOREBUG_TEST_NATIVE_QUALITY: '1' } }),
    100,
  );
  assert.equal(options.fixtureWorkerReportInterval({ environment: {}, cadenceReports: true }), 100);
  assert.equal(options.fixtureWorkerReportInterval({ environment: {}, measuredTrial: true }), 100);
  for (const key of ['cadenceReports', 'measuredTrial']) {
    for (const value of [1, '1', null]) {
      assert.throws(() => options.fixtureWorkerReportInterval({ environment: {}, [key]: value }));
    }
  }
});

test('deadline experiment retains default and requires exact controlled-fixture override', () => {
  assert.equal(options.fixtureDeliveryDeadline({ environment: {}, decoderStall: false }), 1);
  for (const raw of ['1000', '1500']) {
    assert.equal(
      options.fixtureDeliveryDeadline({
        environment: { SCOREBUG_TEST_DELIVERY_DEADLINE_MS: raw },
        decoderStall: true,
      }),
      Number(raw) / 1000,
    );
    assert.throws(
      () =>
        options.fixtureDeliveryDeadline({
          environment: { SCOREBUG_TEST_DELIVERY_DEADLINE_MS: raw },
          decoderStall: false,
        }),
      /deadline/i,
    );
  }
  for (const raw of [
    '',
    '1500.0',
    '01500',
    ' 1500',
    '1500 ',
    '1.5',
    '1e3',
    '2000',
    '0',
    'NaN',
    1500,
    null,
  ])
    assert.throws(
      () =>
        options.fixtureDeliveryDeadline({
          environment: { SCOREBUG_TEST_DELIVERY_DEADLINE_MS: raw },
          decoderStall: true,
        }),
      /deadline/i,
    );
});

test('deadline decisions are isolated behind exact validated experiment flags', () => {
  assert.equal(options.fixtureDeadlineResets({ environment: {}, decoderStall: false }), false);
  const valid = {
    SCOREBUG_TEST_DEADLINE_RESETS: '1',
    SCOREBUG_TEST_DECODER_STALL: '1',
    SCOREBUG_TEST_DELIVERY_DEADLINE_MS: '1500',
    SCOREBUG_TEST_CADENCE_REPORTS: '1',
  };
  for (const stall of ['1', 'reset540']) {
    assert.equal(
      options.fixtureDeadlineResets({
        environment: { ...valid, SCOREBUG_TEST_DECODER_STALL: stall },
        decoderStall: true,
      }),
      true,
    );
  }
  for (const [key, values] of Object.entries({
    SCOREBUG_TEST_DEADLINE_RESETS: ['', '0', 'true', '01', 1, null],
    SCOREBUG_TEST_DECODER_STALL: [undefined, '', '0', 'true'],
    SCOREBUG_TEST_DELIVERY_DEADLINE_MS: [undefined, '1000', '1500.0', 1500],
    SCOREBUG_TEST_CADENCE_REPORTS: [undefined, '', '0', 'true'],
  }))
    for (const value of values) {
      assert.throws(
        () =>
          options.fixtureDeadlineResets({
            environment: { ...valid, [key]: value },
            decoderStall: true,
          }),
        /deadline/i,
      );
    }
  assert.throws(
    () => options.fixtureDeadlineResets({ environment: valid, decoderStall: false }),
    /deadline/i,
  );
});

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
test('structured motion has an explicit workload identity', () => {
  assert.equal(
    options.nativeFixtureWorkload({
      streaming: true,
      environment: {
        SCOREBUG_TEST_MOTION_FIXTURE: 'blocks16',
        SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
      },
    }),
    'motion-blocks16',
  );
});
for (const flag of [
  '',
  '0',
  'true',
  '01',
  ' 1',
  '1 ',
  'blocks16 ',
  'BLOCKS16',
  'blocks8',
  '16',
  1,
  true,
  null,
]) {
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
  for (const flag of ['1', 'blocks16'])
    for (const streaming of [false, true])
      for (const direct of [undefined, 'true', '0', '1']) {
        if (streaming && direct === '1') continue;
        assert.throws(
          () =>
            options.nativeFixtureWorkload({
              streaming,
              environment: {
                SCOREBUG_TEST_MOTION_FIXTURE: flag,
                SCOREBUG_TEST_DIRECT_RTMP_RECORDER: direct,
              },
            }),
          /motion/i,
        );
      }
});

test('decoder threading fixture mode is explicit and rejects unsupported values before setup', () => {
  assert.equal(options.fixtureDecoderThreading({}), 'automatic');
  for (const mode of ['automatic', 'slice'])
    assert.equal(options.fixtureDecoderThreading({ SCOREBUG_TEST_DECODER_THREADING: mode }), mode);
  for (const mode of ['', 'frame', 'Slice', '1', 1, null])
    assert.throws(() => options.fixtureDecoderThreading({ SCOREBUG_TEST_DECODER_THREADING: mode }));
});

test('publishing recovery experiment is exact, bounded and optional', () => {
  assert.equal(options.fixturePublishPeerLatency({}), undefined);
  for (const value of ['120', '400', '2000'])
    assert.equal(
      options.fixturePublishPeerLatency({ SCOREBUG_TEST_PUBLISH_PEER_LATENCY_MS: value }),
      Number(value),
    );
  for (const value of [
    '',
    '0400',
    ' 400',
    '400 ',
    '4e2',
    '+400',
    '400.0',
    '119',
    '2001',
    'NaN',
    400,
    null,
  ])
    assert.throws(
      () => options.fixturePublishPeerLatency({ SCOREBUG_TEST_PUBLISH_PEER_LATENCY_MS: value }),
      /publish.*latency/i,
    );
});

test('relative pacing fixture option is explicit and exact', () => {
  assert.equal(options.fixturePublishPacing({}), undefined);
  assert.equal(
    options.fixturePublishPacing({ SCOREBUG_TEST_PUBLISH_PACING: 'relative' }),
    'relative',
  );
  for (const value of ['', 0, null, '0', 'default', 'Relative', ' relative'])
    assert.throws(
      () => options.fixturePublishPacing({ SCOREBUG_TEST_PUBLISH_PACING: value }),
      /pacing/i,
    );
});

test('source-cadence pacing requires exact opt-in and the validated adaptive fixture', () => {
  assert.equal(
    options.nativeSourceCadencePacing({ environment: {}, adaptiveProfiles: false }),
    false,
  );
  assert.equal(
    options.nativeSourceCadencePacing({
      environment: { SCOREBUG_TEST_SOURCE_CADENCE_PACING: '1' },
      adaptiveProfiles: true,
    }),
    true,
  );
  for (const value of ['', 'true', '0', ' 1'])
    assert.throws(() =>
      options.nativeSourceCadencePacing({
        environment: { SCOREBUG_TEST_SOURCE_CADENCE_PACING: value },
        adaptiveProfiles: true,
      }),
    );
  assert.throws(() =>
    options.nativeSourceCadencePacing({
      environment: { SCOREBUG_TEST_SOURCE_CADENCE_PACING: '1' },
      adaptiveProfiles: false,
    }),
  );
});
