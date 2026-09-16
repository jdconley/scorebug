import assert from 'node:assert/strict';
import { fixtureFrameID } from './video-observation-qualification.mjs';
const uuid = (value) =>
  typeof value === 'string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value);
const finite = (value) => typeof value === 'number' && Number.isFinite(value) && value >= 0;
const mean = (rows) => rows.reduce((n, r) => n + r, 0) / rows.length;
const percentile = (rows, fraction) =>
  [...rows].sort((a, b) => a - b)[Math.ceil(rows.length * fraction) - 1];

/** Actual compressed sample payload, excluding muxer/transport/retransmission.
 * Evidence validity does not presuppose a requested bitrate is achievable. */
export function qualifyEncoderPayload(report) {
  assert.equal(report.formatVersion, 1);
  assert.equal(report.platform, 'iOS Simulator');
  assert.equal(report.workload, 'motion-blocks16');
  assert.equal(report.width, 1920);
  assert.equal(report.height, 1080);
  assert.equal(report.framesPerSecond, 30);
  assert.equal(report.phaseFrames, 600);
  assert.equal(report.settlingFrames, 150);
  assert.equal(report.runs.length, 2);
  const configurations = new Set(),
    sessions = new Set(),
    phases = [];
  let totalFrames = 0;
  for (const [index, run] of report.runs.entries()) {
    assert.equal(run.name, index === 0 ? 'dynamic' : 'freshLow');
    const rates = index === 0 ? [6000000, 1500000, 6000000] : [1500000];
    assert.deepEqual(run.errors, []);
    assert.equal(run.nativeFailure, null);
    assert.equal(
      run.bootstrapNativeBitRate,
      rates[0],
      'Fresh encoder must begin at the requested rate',
    );
    assert.ok(finite(run.pacingAnchor));
    assert.equal(run.receipts.length, rates.length);
    assert.equal(run.frames.length, rates.length * 600 + 1);
    const session = run.receipts[0].encoderSessionID;
    assert.ok(uuid(session) && !sessions.has(session));
    sessions.add(session);
    for (const [i, r] of run.receipts.entries()) {
      assert.equal(r.firstFrame, 1 + i * 600);
      assert.equal(r.frameCount, 600);
      assert.equal(r.bitRate, rates[i]);
      assert.equal(r.lastSubmittedFrame, i * 600);
      assert.ok(uuid(r.configurationID) && !configurations.has(r.configurationID));
      configurations.add(r.configurationID);
      assert.equal(r.encoderSessionID, session);
      assert.ok(finite(r.acceptedAt));
      assert.ok(r.acceptedAt >= run.frames[r.lastSubmittedFrame].submittedAt);
      assert.ok(r.acceptedAt <= run.frames[r.firstFrame].submittedAt);
    }
    const lags = [],
      gaps = [],
      completionLags = [];
    for (const [i, f] of run.frames.entries()) {
      assert.equal(f.frame, i);
      assert.equal(fixtureFrameID(f.sourcePTS), i);
      assert.equal(fixtureFrameID(f.outputPTS), i);
      assert.equal(f.encoderSessionID, session);
      const receipt = i ? run.receipts[Math.floor((i - 1) / 600)] : null;
      assert.equal(f.configurationID, receipt?.configurationID ?? null);
      assert.equal(f.configuredBitRate, receipt?.bitRate ?? null);
      assert.ok(
        Number.isSafeInteger(f.bytes) && f.bytes > 0 && f.bytes <= 2 * 1024 * 1024,
        'Invalid encoded sample bytes',
      );
      assert.ok(finite(f.submittedAt) && finite(f.completedAt) && finite(f.deliveredAt));
      assert.ok(f.completedAt >= f.submittedAt && f.deliveredAt >= f.completedAt);
      if (receipt) assert.ok(f.submittedAt >= receipt.acceptedAt);
      completionLags.push(f.completedAt - f.submittedAt);
      if (i) {
        const lag = f.submittedAt - (run.pacingAnchor + i / 30);
        assert.ok(lag >= -0.005 && lag <= 0.25, 'Source was not paced in real time');
        lags.push(lag);
      }
      if (i > 1) {
        const gap = f.submittedAt - run.frames[i - 1].submittedAt;
        assert.ok(gap >= 1 / 120, 'Catch-up burst invalidates paced encoder measurement');
        gaps.push(gap);
      }
    }
    assert.ok(percentile(gaps, 0.95) <= 0.05, 'Source pacing gap budget exceeded');
    const sourceFPS =
      (run.frames.length - 2) / (run.frames.at(-1).submittedAt - run.frames[1].submittedAt);
    assert.ok(sourceFPS >= 29 && sourceFPS <= 31);
    totalFrames += run.frames.length;
    for (const [i, r] of run.receipts.entries()) {
      const settled = run.frames.slice(r.firstFrame + 150, r.firstFrame + 600);
      const windows = [];
      for (let j = 0; j < 3; j++) {
        const rows = settled.slice(j * 150, (j + 1) * 150);
        assert.equal(rows.length, 150);
        const bytes = rows.reduce((n, f) => n + f.bytes, 0);
        windows.push({
          firstFrame: rows[0].frame,
          lastFrame: rows.at(-1).frame,
          bytes,
          seconds: 5,
          mbps: (bytes * 8) / 5 / 1e6,
        });
      }
      phases.push({
        run: run.name,
        phase: i,
        requestedBitRate: r.bitRate,
        configurationID: r.configurationID,
        encoderSessionID: session,
        windows,
        meanMbps: mean(windows.map((w) => w.mbps)),
        sourceFPS,
        maximumSubmissionLateness: Math.max(...lags),
        maximumCompletionLag: Math.max(...completionLags),
      });
    }
  }
  return {
    frames: totalFrames,
    phases,
    dynamicLowToInitialHigh: phases[1].meanMbps / phases[0].meanMbps,
    dynamicLowToFreshLow: phases[1].meanMbps / phases[3].meanMbps,
    freshLowToRequested: phases[3].meanMbps / 1.5,
    restoredHighToInitialHigh: phases[2].meanMbps / phases[0].meanMbps,
    scope:
      'Compressed H.264 sample payload under paced simulator input; not network capacity, recovery or physical-device qualification.',
  };
}
