import test from 'node:test';
import assert from 'node:assert/strict';
import { qualifyEncoderPayload } from '../encoder-payload-qualification.mjs';
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
