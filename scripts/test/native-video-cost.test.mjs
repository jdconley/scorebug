import assert from 'node:assert/strict';
import test from 'node:test';
import { qualifyNativeVideoCost } from '../native-video-cost.mjs';
const session = '00000000-0000-4000-8000-000000000001';
const pts = (n) => ({ value: String(7395 + 2 * n), timescale: 60, epoch: '0', flags: 1 });
function fixture() {
  const scope = {
    recordingID: 'r',
    matchID: 'g',
    broadcastGeneration: 1,
    publishingAttemptID: session,
    appliedProfileRevision: '0',
  };
  const compressed = Array.from({ length: 61 }, (_, n) => ({
    sourcePTS: pts(n),
    publishingGeneration: '1',
    width: 960,
    height: 540,
    bytes: n ? 1000 : 9000,
    dequeuedAt: 100 + n / 30 + 0.02,
    valid: true,
    wasEncoded: true,
    codec: 1635148593,
  }));
  const encoded = compressed.map((r, n) => ({
    sourcePTS: r.sourcePTS,
    outputPTS: r.sourcePTS,
    encoderSessionID: session,
    configurationID: null,
    configuredBitRate: null,
    submittedAt: 100 + n / 30,
    completedAt: 100 + n / 30 + 0.01,
  }));
  const intervals = [
    {
      sequence: '1',
      publishingGeneration: '1',
      encoderSessionID: session,
      configurationID: null,
      configuredBitRate: null,
      width: 960,
      height: 540,
      sourceStartExclusive: pts(0),
      sourceEndInclusive: pts(60),
      submissionStart: 100,
      submissionEnd: 102,
      observedAt: 102.02,
      frames: 60,
      maximumFrameBytes: 1000,
      payloadBytes: '60000',
      maximumLatency: 0.02,
      maximumSourceGap: 1 / 30,
      sourceDuration: 2,
      submissionDuration: 2,
      payloadBitsPerSecond: 240000,
      usable: true,
    },
  ];
  return {
    proof: {
      formatVersion: 1,
      isClosed: true,
      invalidReason: null,
      scope,
      profile: '540p30',
      compressed,
      encoded,
      intervals,
    },
    format: {
      scope,
      width: 960,
      height: 540,
      firstFrame: 0,
      lastFrame: 60,
      frames: 61,
      publishingGeneration: '1',
    },
  };
}
test('reconstructs actual payload cost without using configured bitrate', () => {
  const { proof, format } = fixture();
  const r = qualifyNativeVideoCost(proof, format);
  assert.equal(r.intervalCount, 1);
  assert.equal(r.maximumPayloadBitsPerSecond, 240000);
  assert.equal(r.usableCapacity, false);
});
for (const [name, damage] of Object.entries({
  bytes: (p) => (p.intervals[0].payloadBytes = '59000'),
  anchor: (p) => (p.intervals[0].payloadBytes = '69000'),
  rate: (p) => (p.intervals[0].payloadBitsPerSecond = 230000),
  session: (p) => (p.encoded[40].encoderSessionID = '00000000-0000-4000-8000-000000000002'),
  configuration: (p) => (p.intervals[0].configurationID = session),
  stale: (p) => (p.intervals[0].observedAt = 100),
  duration: (p) => (p.intervals[0].submissionEnd = 101),
  gap: (p) => (p.intervals[0].maximumSourceGap = 0),
  duplicate: (p) => (p.compressed[30] = p.compressed[29]),
  missing: (p) => p.encoded.splice(30, 1),
  size: (p) => (p.compressed[30].width = 1920),
  closed: (p) => (p.isClosed = false),
  invalid: (p) => (p.invalidReason = 'incompleteJoin'),
  frameCount: (p) => (p.intervals[0].frames = 59),
  unusable: (p) => (p.intervals[0].usable = false),
  overflow: (p) => p.intervals.push(...Array.from({ length: 8 }, () => p.intervals[0])),
  source: (p) => (p.encoded[30].outputPTS = pts(31)),
}))
  test('rejects damaged cost: ' + name, () => {
    const { proof, format } = fixture();
    damage(proof);
    assert.throws(() => qualifyNativeVideoCost(proof, format));
  });
function twoWindows() {
  const f = fixture(),
    { proof: p, format } = f;
  const e = structuredClone(p.encoded[60]),
    c = structuredClone(p.compressed[60]);
  for (let n = 61; n <= 120; n++) {
    p.encoded.push({
      ...e,
      sourcePTS: pts(n),
      outputPTS: pts(n),
      submittedAt: 100 + n / 30,
      completedAt: 100 + n / 30 + 0.01,
    });
    p.compressed.push({ ...c, sourcePTS: pts(n), dequeuedAt: 100 + n / 30 + 0.02 });
  }
  p.intervals.push({
    ...p.intervals[0],
    sequence: '2',
    sourceStartExclusive: pts(60),
    sourceEndInclusive: pts(120),
    submissionStart: 102,
    submissionEnd: 104,
    observedAt: 104.02,
  });
  format.lastFrame = 120;
  format.frames = 121;
  return f;
}
test('qualifies complete two-window control', () => {
  const f = twoWindows();
  assert.equal(qualifyNativeVideoCost(f.proof, f.format).intervalCount, 2);
});
for (const side of ['newest', 'oldest'])
  test('rejects omitted ' + side + ' window', () => {
    const f = twoWindows();
    if (side === 'newest') f.proof.intervals.pop();
    else f.proof.intervals.shift();
    assert.throws(() => qualifyNativeVideoCost(f.proof, f.format));
  });

test('fixed360 cost reconciles actual payload and rejects crossed profile geometry', () => {
  const { proof, format } = fixture();
  proof.profile = '360p30'; format.width = 640; format.height = 360;
  for (const row of [...proof.compressed, ...proof.intervals]) { row.width = 640; row.height = 360; }
  assert.equal(qualifyNativeVideoCost(proof, format).maximumPayloadBitsPerSecond, 240000);
  proof.profile = '540p30';
  assert.throws(() => qualifyNativeVideoCost(proof, format));
});
