import assert from 'node:assert/strict';
import { fixtureFrameID } from './video-observation-qualification.mjs';
import { qualifyNativeEncoderSnapshot } from './encoder-native-properties.mjs';
const finite = (n) => typeof n === 'number' && Number.isFinite(n) && n >= 0;
const uuid = (v) =>
  typeof v === 'string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(v);

/** Same codec, successive native sessions; no transport or decode claim. */
export function qualifyEncoderResolutionTransition(report) {
  assert.ok([7, 8].includes(report.formatVersion));
  const drained = report.formatVersion === 8;
  assert.equal(
    report.experiment,
    drained ? 'drained-resolution-transitions' : 'live-resolution-transitions',
  );
  assert.equal(report.platform, 'iOS Simulator');
  assert.equal(report.workload, 'motion-blocks16');
  assert.equal(report.width, 1920);
  assert.equal(report.height, 1080);
  assert.equal(report.framesPerSecond, 30);
  assert.equal(report.phaseFrames, 600);
  assert.equal(report.settlingFrames, 150);
  assert.equal(
    report.nativeFailure,
    null,
    'Native encoder failed: ' + String(report.nativeFailure).slice(0, 256),
  );
  assert.deepEqual(report.errors, []);
  assert.equal(report.phases.length, 3);
  assert.equal(report.frames.length, 1800);
  assert.ok(finite(report.pacingAnchor));
  const sessions = new Set(),
    phases = [],
    gaps = [],
    lags = [];
  for (const [i, p] of report.phases.entries()) {
    assert.equal(p.firstFrame, i * 600);
    assert.equal(p.frameCount, 600);
    assert.equal(p.width, i === 1 ? 960 : 1920);
    assert.equal(p.height, i === 1 ? 540 : 1080);
    assert.equal(p.bitRate, i === 1 ? 1500000 : 6000000);
    assert.equal(p.sessionReplaced, true);
    qualifyNativeEncoderSnapshot(p.native, p.bitRate);
    assert.ok(uuid(p.native.encoderSessionID) && !sessions.has(p.native.encoderSessionID));
    sessions.add(p.native.encoderSessionID);
    assert.ok(finite(p.requestedAt) && finite(p.appendBeganAt) && finite(p.appendEndedAt));
    assert.ok(p.requestedAt <= p.appendBeganAt && p.appendBeganAt <= p.appendEndedAt);
    if (drained) {
      if (i) {
        assert.ok(finite(p.replacementDrainStartedAt) && finite(p.replacementDrainEndedAt));
        assert.equal(p.replacementDrainStatus, 0);
        assert.ok(p.requestedAt <= p.replacementDrainStartedAt);
        assert.ok(p.replacementDrainStartedAt <= p.replacementDrainEndedAt);
        assert.ok(p.replacementDrainEndedAt <= p.appendBeganAt);
        for (const frame of report.frames.slice(p.firstFrame - 600, p.firstFrame)) {
          assert.ok(
            frame.completedAt <= p.replacementDrainEndedAt,
            'Successful drain must complete every callback from the old session',
          );
        }
      } else {
        assert.equal(p.replacementDrainStartedAt, null);
        assert.equal(p.replacementDrainEndedAt, null);
        assert.equal(p.replacementDrainStatus, null);
      }
    }
    const first = report.frames[p.firstFrame];
    assert.ok(p.appendBeganAt <= first.submittedAt && first.submittedAt <= p.appendEndedAt);
    assert.ok(p.native.collectedAt >= p.appendEndedAt);
    assert.ok(p.native.completedAt <= report.frames[p.firstFrame + 1].submittedAt);
    if (i) assert.ok(p.requestedAt >= report.frames[p.firstFrame - 1].submittedAt);
    else assert.ok(p.native.completedAt <= report.pacingAnchor);
    assert.equal(first.isSync, true, 'New encoder phase must begin with a sync frame');
    assert.equal(first.hasIDR, true, 'New encoder phase must contain an IDR NAL');
    const rows = report.frames.slice(p.firstFrame + 150, p.firstFrame + 600);
    const windows = Array.from({ length: 3 }, (_, j) => {
      const frames = rows.slice(j * 150, (j + 1) * 150),
        bytes = frames.reduce((n, f) => n + f.bytes, 0);
      return {
        firstFrame: frames[0].frame,
        lastFrame: frames.at(-1).frame,
        bytes,
        seconds: 5,
        mbps: (bytes * 8) / 5 / 1e6,
      };
    });
    phases.push({
      width: p.width,
      height: p.height,
      requestedBitRate: p.bitRate,
      encoderSessionID: p.native.encoderSessionID,
      firstFrame: p.firstFrame,
      lastFrame: p.firstFrame + 599,
      windows,
      meanMbps: windows.reduce((n, w) => n + w.mbps, 0) / 3,
      firstAppendSeconds: p.appendEndedAt - p.appendBeganAt,
      replacementDrainSeconds:
        drained && i ? p.replacementDrainEndedAt - p.replacementDrainStartedAt : null,
      transitionDeliveryGapSeconds: i
        ? first.deliveredAt - report.frames[p.firstFrame - 1].deliveredAt
        : null,
      firstCompletionLagSeconds: first.completedAt - first.submittedAt,
    });
  }
  for (const [i, f] of report.frames.entries()) {
    const p = report.phases[Math.floor(i / 600)];
    assert.equal(f.frame, i);
    assert.equal(fixtureFrameID(f.sourcePTS), i);
    assert.equal(fixtureFrameID(f.outputPTS), i);
    assert.equal(f.deliveryOrdinal, i, 'Output must preserve source order across transitions');
    assert.equal(f.encoderSessionID, p.native.encoderSessionID);
    assert.equal(f.configurationID, null);
    assert.equal(f.configuredBitRate, null);
    assert.equal(f.encodedWidth, p.width);
    assert.equal(f.encodedHeight, p.height);
    assert.equal(typeof f.isSync, 'boolean');
    assert.equal(typeof f.hasIDR, 'boolean');
    assert.deepEqual(f.parameterSetTypes, [7, 8]);
    assert.equal(f.nalUnitHeaderLength, 4);
    assert.ok(Number.isSafeInteger(f.bytes) && f.bytes > 0 && f.bytes <= 2 * 1024 * 1024);
    assert.ok(finite(f.submittedAt) && finite(f.completedAt) && finite(f.deliveredAt));
    assert.ok(f.submittedAt <= f.completedAt && f.completedAt <= f.deliveredAt);
    if (i) {
      const lag = f.submittedAt - (report.pacingAnchor + i / 30);
      assert.ok(lag >= -0.005 && lag <= 0.25, 'Source was not paced in real time');
      lags.push(lag);
      assert.ok(f.deliveredAt >= report.frames[i - 1].deliveredAt);
    }
    if (i > 1) {
      const gap = f.submittedAt - report.frames[i - 1].submittedAt;
      assert.ok(gap >= 1 / 120, 'Catch-up burst invalidates transition pacing');
      gaps.push(gap);
    }
  }
  const sorted = [...gaps].sort((a, b) => a - b);
  assert.ok(sorted[Math.ceil(sorted.length * 0.95) - 1] <= 0.05);
  const sourceFPS = 1798 / (report.frames.at(-1).submittedAt - report.frames[1].submittedAt);
  assert.ok(sourceFPS >= 29 && sourceFPS <= 31);
  return {
    frames: 1800,
    phases,
    sourceFPS,
    maximumSubmissionLateness: Math.max(...lags),
    maximumCompletionLag: Math.max(...report.frames.map((f) => f.completedAt - f.submittedAt)),
    scope:
      'Paced simulator encoder transitions and compressed sample metadata; not decoded video, network continuity, archive isolation during changes, automatic adaptation or physical-device qualification.',
  };
}
