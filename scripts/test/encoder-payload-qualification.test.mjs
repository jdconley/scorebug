import test from 'node:test';
import assert from 'node:assert/strict';
import { qualifyEncoderPayload } from '../encoder-payload-qualification.mjs';
import { nativeEncoderProperties } from '../encoder-native-properties.mjs';
const uuid = (n) => '00000000-0000-4000-8000-' + String(n).padStart(12, '0');
function fixture() {
  const run = (name, rates, session) => {
    const receipts = rates.map((bitRate, i) => ({
      firstFrame: 1 + i * 600,
      frameCount: 600,
      bitRate,
      configurationID: uuid(session * 10 + i + 1),
      encoderSessionID: uuid(session),
      acceptedAt: 100 + i * 20 + 0.02,
      lastSubmittedFrame: i * 600,
    }));
    const frames = Array.from({ length: rates.length * 600 + 1 }, (_, frame) => {
      const phase = frame ? Math.floor((frame - 1) / 600) : null;
      const receipt = phase === null ? null : receipts[phase],
        at = 100 + frame / 30;
      const pts = { value: String(7395 + 2 * frame), timescale: 60, epoch: '0', flags: 1 };
      return {
        frame,
        sourcePTS: pts,
        outputPTS: { ...pts },
        encoderSessionID: uuid(session),
        configurationID: receipt?.configurationID ?? null,
        configuredBitRate: receipt?.bitRate ?? null,
        submittedAt: at,
        completedAt: at + 0.01,
        deliveredAt: at + 0.011,
        bytes: frame ? (receipt.bitRate === 1500000 ? 6250 : 25000) : 25000,
      };
    });
    return {
      name,
      receipts,
      frames,
      pacingAnchor: 100,
      bootstrapNativeBitRate: rates[0],
      errors: [],
      nativeFailure: null,
    };
  };
  return {
    formatVersion: 1,
    platform: 'iOS Simulator',
    workload: 'motion-blocks16',
    width: 1920,
    height: 1080,
    framesPerSecond: 30,
    phaseFrames: 600,
    settlingFrames: 150,
    runs: [run('dynamic', [6000000, 1500000, 6000000], 1), run('freshLow', [1500000], 2)],
  };
}
test('qualifies actual source-window payload separately from requested rates', () => {
  const r = qualifyEncoderPayload(fixture());
  assert.equal(r.frames, 2402);
  assert.equal(r.phases.length, 4);
  assert.equal(r.phases[1].meanMbps, 1.5);
  assert.equal(r.dynamicLowToInitialHigh, 0.25);
  assert.equal(r.dynamicLowToFreshLow, 1);
});
test('retains a content floor or ineffective changes as diagnostics, not false throughput claims', () => {
  const f = fixture();
  for (const r of f.runs) for (const row of r.frames) row.bytes = 25000;
  const result = qualifyEncoderPayload(f);
  assert.equal(result.dynamicLowToInitialHigh, 1);
  assert.equal(result.freshLowToRequested, 4);
});
function withNativeSnapshots() {
  const report = fixture();
  report.formatVersion = 2;
  for (const run of report.runs) {
    const snapshot = (rate, at) => {
      const properties = Object.fromEntries(
        nativeEncoderProperties.map((key) => [
          key,
          {
            supported: false,
            status: -12900,
            value: null,
            type: null,
            readWriteStatus: null,
          },
        ]),
      );
      for (const [key, value] of Object.entries({
        EncoderID: 'observed.encoder',
        AverageBitRate: rate,
        DataRateLimits: [(rate / 8) * 1.5, 1],
      })) {
        properties[key] = { supported: true, status: 0, value, type: null, readWriteStatus: null };
      }
      return {
        supportedQueryStatus: 0,
        properties,
        encoderSessionID: run.receipts[0].encoderSessionID,
        collectedAt: at,
        completedAt: at + 0.001,
      };
    };
    run.native = {
      bootstrap: snapshot(run.receipts[0].bitRate, 99),
      final: snapshot(run.receipts.at(-1).bitRate, 200),
    };
  }
  return report;
}
test('version 2 binds bounded native snapshots to session ownership and measurement boundaries', () => {
  assert.equal(qualifyEncoderPayload(withNativeSnapshots()).frames, 2402);
  for (const mutate of [
    (r) => delete r.runs[0].native,
    (r) => delete r.runs[0].native.final,
    (r) => (r.runs[0].native.final.encoderSessionID = uuid(999)),
    (r) => (r.runs[0].native.bootstrap.completedAt = 101),
    (r) => (r.runs[0].native.final.collectedAt = 110),
    (r) => (r.runs[0].native.final.properties.EncoderID.value = 'different.encoder'),
    (r) => (r.runs[1].native.bootstrap.properties.AverageBitRate.value = 6000000),
  ]) {
    const report = withNativeSnapshots();
    mutate(report);
    assert.throws(() => qualifyEncoderPayload(report));
  }
});
function preparationFixture() {
  const report = withNativeSnapshots();
  report.formatVersion = 3;
  report.experiment = 'frame-rate-before-prepare';
  const template = report.runs[1];
  report.runs = [structuredClone(template), structuredClone(template)];
  for (const [i, run] of report.runs.entries()) {
    run.name = i === 0 ? 'freshLate' : 'freshEarly';
    run.preparation = i === 0 ? 'production' : 'expectedFrameRateBeforePrepare';
    const session = uuid(100 + i),
      configuration = uuid(200 + i);
    for (const snapshot of Object.values(run.native)) snapshot.encoderSessionID = session;
    run.receipts[0].encoderSessionID = session;
    run.receipts[0].configurationID = configuration;
    for (const frame of run.frames) {
      frame.encoderSessionID = session;
      if (frame.frame) frame.configurationID = configuration;
    }
  }
  return report;
}
test('version 3 qualifies only the fixed fresh preparation-order comparison', () => {
  const report = preparationFixture();
  const result = qualifyEncoderPayload(report);
  assert.equal(result.frames, 1202);
  assert.equal(result.earlyToLate, 1);
  for (const mutate of [
    (r) => (r.experiment = 'different'),
    (r) => r.runs.reverse(),
    (r) => (r.runs[1].preparation = 'production'),
    (r) => (r.runs[0].receipts[0].bitRate = 6000000),
    (r) => r.runs[1].frames.pop(),
    (r) => delete r.runs[1].native,
  ]) {
    const report = preparationFixture();
    mutate(report);
    assert.throws(() => qualifyEncoderPayload(report));
  }
});
function resolutionFixture() {
  const report = preparationFixture();
  report.formatVersion = 4;
  report.experiment = 'fresh-resolution-profiles';
  for (const [i, run] of report.runs.entries()) {
    delete run.preparation;
    run.name = i === 0 ? 'fresh1080p' : 'fresh720p';
    run.encodedWidth = i === 0 ? 1920 : 1280;
    run.encodedHeight = i === 0 ? 1080 : 720;
    for (const frame of run.frames) {
      frame.encodedWidth = run.encodedWidth;
      frame.encodedHeight = run.encodedHeight;
    }
  }
  return report;
}
test('version 4 validates actual dimensions for every encoded resolution-comparison frame', () => {
  assert.equal(qualifyEncoderPayload(resolutionFixture()).reducedToFull, 1);
  for (const mutate of [
    (r) => (r.experiment = 'different'),
    (r) => (r.width = 1280),
    (r) => r.runs.reverse(),
    (r) => (r.runs[1].encodedWidth = 1920),
    (r) => (r.runs[1].frames[350].encodedWidth = 1920),
    (r) => delete r.runs[0].frames[0].encodedHeight,
  ]) {
    const report = resolutionFixture();
    mutate(report);
    assert.throws(() => qualifyEncoderPayload(report));
  }
});
test('rejects mixed identities, dropped frames, invalid bytes and receipt timing', () => {
  for (const mutate of [
    (f) => (f.platform = 'macOS'),
    (f) => (f.workload = 'barcode'),
    (f) => f.runs.pop(),
    (f) => f.runs[0].frames.pop(),
    (f) => (f.runs[0].frames[4].frame = 3),
    (f) => (f.runs[0].frames[3].bytes = 0),
    (f) => (f.runs[0].frames[3].bytes = 2 ** 22),
    (f) => (f.runs[0].frames[3].bytes = NaN),
    (f) => (f.runs[0].frames[3].configurationID = uuid(99)),
    (f) => (f.runs[0].frames[3].encoderSessionID = uuid(2)),
    (f) => (f.runs[0].frames[3].configuredBitRate = 1500000),
    (f) => (f.runs[0].frames[3].sourcePTS.value = '7400'),
    (f) => (f.runs[0].frames[3].outputPTS.value = '7400'),
    (f) => (f.runs[0].receipts[1].lastSubmittedFrame = 599),
    (f) => (f.runs[0].receipts[1].acceptedAt = 200),
    (f) => (f.runs[0].frames[3].completedAt = 0),
    (f) => (f.runs[0].frames[3].deliveredAt = 0),
    (f) => (f.runs[0].frames[3].submittedAt = NaN),
    (f) => f.runs[0].errors.push('duplicate'),
    (f) => (f.runs[1].bootstrapNativeBitRate = 6000000),
    (f) => (f.runs[0].frames[100].submittedAt += 1),
    (f) => (f.runs[0].nativeFailure = 'failed'),
    (f) => (f.runs[1].receipts[0].configurationID = f.runs[0].receipts[0].configurationID),
    (f) => (f.runs[1].receipts[0].encoderSessionID = f.runs[0].receipts[0].encoderSessionID),
  ]) {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualifyEncoderPayload(f));
  }
});
