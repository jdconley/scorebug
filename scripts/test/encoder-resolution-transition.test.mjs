import test from 'node:test';
import assert from 'node:assert/strict';
import { qualifyEncoderPayload } from '../encoder-payload-qualification.mjs';
import { nativeEncoderProperties } from '../encoder-native-properties.mjs';
const uuid = (n) => '00000000-0000-4000-8000-' + String(n).padStart(12, '0');
function fixture() {
  const rates = [6000000, 1500000, 6000000];
  const phases = rates.map((bitRate, i) => {
    const firstFrame = i * 600,
      at = i === 0 ? 99 : 100 + firstFrame / 30;
    const properties = Object.fromEntries(
      nativeEncoderProperties.map((key) => [
        key,
        { supported: false, status: -12900, value: null, type: null, readWriteStatus: null },
      ]),
    );
    for (const [key, value] of Object.entries({
      EncoderID: 'observed.encoder',
      AverageBitRate: bitRate,
      DataRateLimits: [(bitRate / 8) * 1.5, 1],
    }))
      properties[key] = { supported: true, status: 0, value, type: null, readWriteStatus: null };
    return {
      firstFrame,
      frameCount: 600,
      width: i === 1 ? 960 : 1920,
      height: i === 1 ? 540 : 1080,
      bitRate,
      requestedAt: at - 0.002,
      appendBeganAt: at - 0.001,
      appendEndedAt: at + 0.002,
      sessionReplaced: true,
      native: {
        supportedQueryStatus: 0,
        properties,
        encoderSessionID: uuid(i + 1),
        collectedAt: at + 0.003,
        completedAt: at + 0.004,
      },
    };
  });
  const frames = Array.from({ length: 1800 }, (_, i) => {
    const phase = phases[Math.floor(i / 600)],
      at = i === 0 ? 99 : 100 + i / 30;
    const pts = { value: String(7395 + i * 2), timescale: 60, epoch: '0', flags: 1 };
    return {
      frame: i,
      sourcePTS: pts,
      outputPTS: { ...pts },
      encoderSessionID: phase.native.encoderSessionID,
      configurationID: null,
      configuredBitRate: null,
      submittedAt: at,
      completedAt: at + 0.001,
      deliveredAt: at + 0.002,
      deliveryOrdinal: i,
      bytes: phase.bitRate / 240,
      encodedWidth: phase.width,
      encodedHeight: phase.height,
      isSync: i % 60 === 0,
      hasIDR: i % 60 === 0,
      parameterSetTypes: [7, 8],
      nalUnitHeaderLength: 4,
    };
  });
  return {
    formatVersion: 7,
    experiment: 'live-resolution-transitions',
    platform: 'iOS Simulator',
    workload: 'motion-blocks16',
    width: 1920,
    height: 1080,
    framesPerSecond: 30,
    phaseFrames: 600,
    settlingFrames: 150,
    pacingAnchor: 100,
    nativeFailure: null,
    errors: [],
    phases,
    frames,
  };
}
test('qualifies exact native source and session ownership across down/up resolution changes', () => {
  const result = qualifyEncoderPayload(fixture());
  assert.equal(result.frames, 1800);
  assert.equal(result.phases.length, 3);
  assert.equal(result.phases[1].meanMbps, 1.5);
  assert.equal(result.phases[2].width, 1920);
  assert.equal(result.phases[0].transitionDeliveryGapSeconds, null);
  assert.ok(Math.abs(result.phases[1].transitionDeliveryGapSeconds - 1 / 30) < 1e-10);
  assert.match(result.scope, /not.*network/);
});
test('rejects missing frames, mixed sessions, stale formats, undecodable phase starts and unpaced changes', () => {
  for (const mutate of [
    (r) => r.frames.splice(599, 1),
    (r) => (r.frames[600].frame = 599),
    (r) => (r.frames[600].encoderSessionID = uuid(1)),
    (r) => (r.phases[2].native.encoderSessionID = uuid(1)),
    (r) => (r.frames[602].encodedWidth = 1920),
    (r) => (r.frames[600].isSync = false),
    (r) => (r.frames[1200].hasIDR = false),
    (r) => (r.frames[600].parameterSetTypes = [7]),
    (r) => (r.frames[600].nalUnitHeaderLength = 3),
    (r) => (r.frames[599].deliveryOrdinal = 600),
    (r) => (r.frames[599].outputPTS.value = '7400'),
    (r) => (r.frames[601].submittedAt += 1),
    (r) => (r.frames[601].completedAt = 0),
    (r) => (r.frames[602].bytes = 0),
    (r) => (r.phases[1].firstFrame = 601),
    (r) => (r.phases[1].requestedAt = 121),
    (r) => (r.phases[1].appendEndedAt = 0),
    (r) => (r.phases[1].native.collectedAt = 0),
    (r) => (r.phases[1].native.completedAt = 130),
    (r) => (r.phases[1].sessionReplaced = false),
    (r) => (r.phases[1].native.properties.AverageBitRate.value = 6000000),
    (r) => (r.nativeFailure = 'codecFailed(status: -1)'),
    (r) => r.errors.push('overflow'),
    (r) => (r.frames[599].configurationID = uuid(99)),
    (r) => (r.frames[599].configuredBitRate = 6000000),
    (r) => (r.frames[0].submittedAt = -1),
    (r) => (r.frames[1799].deliveredAt = NaN),
  ]) {
    const report = fixture();
    mutate(report);
    assert.throws(() => qualifyEncoderPayload(report));
  }
});

function drainedFixture() {
  const report = fixture();
  report.formatVersion = 8;
  report.experiment = 'drained-resolution-transitions';
  for (const [i, phase] of report.phases.entries()) {
    phase.replacementDrainStartedAt = i ? phase.requestedAt : null;
    phase.replacementDrainEndedAt = i ? phase.requestedAt + 0.0005 : null;
    phase.replacementDrainStatus = i ? 0 : null;
  }
  return report;
}
test('qualifies explicit native drain boundaries separately from new-session startup', () => {
  const result = qualifyEncoderPayload(drainedFixture());
  assert.equal(result.frames, 1800);
  assert.equal(result.phases[0].replacementDrainSeconds, null);
  assert.ok(Math.abs(result.phases[1].replacementDrainSeconds - 0.0005) < 1e-10);
});
test('rejects missing, failed or mistimed native replacement drains', () => {
  for (const mutate of [
    (r) => (r.experiment = 'live-resolution-transitions'),
    (r) => (r.phases[0].replacementDrainStatus = 0),
    (r) => delete r.phases[1].replacementDrainStartedAt,
    (r) => (r.phases[1].replacementDrainStatus = -77),
    (r) => (r.phases[1].replacementDrainStartedAt = r.phases[1].requestedAt - 0.1),
    (r) => (r.phases[1].replacementDrainEndedAt = r.phases[1].appendBeganAt + 0.1),
    (r) => (r.phases[1].replacementDrainEndedAt = r.phases[1].replacementDrainStartedAt - 0.1),
  ]) {
    const report = drainedFixture();
    mutate(report);
    assert.throws(() => qualifyEncoderPayload(report));
  }
});

test('successful drain must include every prior-session callback, not just preserve delivery order', () => {
  const report = drainedFixture();
  const ended = report.phases[1].replacementDrainEndedAt;
  report.frames[599].completedAt = ended + 0.00001;
  report.frames[599].deliveredAt = ended + 0.00002;
  assert.throws(() => qualifyEncoderPayload(report));
});
test('a completed old-session sample may remain queued after drain returns', () => {
  const report = drainedFixture();
  report.frames[599].deliveredAt = report.phases[1].replacementDrainEndedAt + 0.00002;
  assert.equal(qualifyEncoderPayload(report).frames, 1800);
});
