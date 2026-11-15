import test from 'node:test';
import assert from 'node:assert/strict';
import { qualifyNativeCompressedFrames } from '../native-compressed-frames.mjs';

const pts = (id) => ({ value: String(7395 + id * 2), timescale: 60, epoch: '0', flags: 1 });
function fixture() {
  const compressedFrames = Array.from({ length: 12 }, (_, id) => ({
    sourcePTS: pts(id),
    observedAt: 100 + id * 0.04,
    byteCount: id % 4 === 0 ? 4000 : 1000,
    isSync: id % 4 === 0,
  }));
  const phases = [0, 1, 2].map((index) => {
    const rows = compressedFrames.slice(index * 4, index * 4 + 4);
    return {
      frames: 4,
      firstSourcePTS: rows[0].sourcePTS,
      lastSourcePTS: rows.at(-1).sourcePTS,
      firstObservedAt: rows[0].observedAt,
      lastObservedAt: rows.at(-1).observedAt,
      maximumSourceGapSeconds: 1 / 30,
      maximumObservationGapSeconds: Math.max(
        ...rows.slice(1).map((r, i) => r.observedAt - rows[i].observedAt),
      ),
    };
  });
  return {
    format: {
      formatVersion: 4,
      isClosed: true,
      invalid: false,
      frames: 12,
      compressedFrames,
      scope: { recordingID: 'r' },
      publishingGeneration: '1',
      phases,
    },
    snapshot: {
      scope: { recordingID: 'r' },
      isClosed: true,
      monotonicAnchor: 99,
      captureDetachedAt: 102,
      publishingClockObservation: { publishingGeneration: '1' },
    },
  };
}
test('actual compressed bytes and sync points reconcile with source and callback phase boundaries', () => {
  const { format, snapshot } = fixture();
  const result = qualifyNativeCompressedFrames(format, snapshot);
  assert.equal(result.frames, 12);
  assert.equal(result.totalBytes, 21000);
  assert.deepEqual(
    result.phases.map((p) => p.totalBytes),
    [7000, 7000, 7000],
  );
  assert.deepEqual(
    result.phases.flatMap((p) => p.syncFrames.map((s) => s.frameID)),
    [0, 4, 8],
  );
  assert.equal(result.phases[0].maximumFrameBytes, 4000);
  assert.deepEqual(result.phases[0].peak100ms, { index: 0, bytes: 6000, frames: 3 });
});
test('missing, malformed, oversized, reordered and contradictory raw records cannot qualify', () => {
  const changes = [
    (f) => {
      delete f.compressedFrames;
    },
    (f) => {
      f.compressedFrames.pop();
    },
    (f) => {
      f.compressedFrames.push(f.compressedFrames[0]);
    },
    (f) => {
      f.frames = 25001;
    },
    (f) => {
      f.compressedFrames[1].byteCount = 0;
    },
    (f) => {
      f.compressedFrames[1].byteCount = -1;
    },
    (f) => {
      f.compressedFrames[1].byteCount = 1.5;
    },
    (f) => {
      f.compressedFrames[1].byteCount = Number.MAX_SAFE_INTEGER;
    },
    (f) => {
      f.compressedFrames[1].isSync = null;
    },
    (f) => {
      f.compressedFrames[1].isSync = 'false';
    },
    (f) => {
      f.compressedFrames[4].isSync = false;
    },
    (f) => {
      f.compressedFrames[1].sourcePTS = pts(0);
    },
    (f) => {
      f.compressedFrames[1].observedAt = 99;
    },
    (f) => {
      f.compressedFrames[1].observedAt = NaN;
    },
    (f) => {
      f.compressedFrames[1].observedAt = 104;
    },
    (f) => {
      f.phases[0].frames = 3;
    },
    (f) => {
      f.phases[0].firstSourcePTS = pts(1);
    },
    (f) => {
      f.phases[0].lastSourcePTS = pts(2);
    },
    (f) => {
      f.phases[0].firstObservedAt += 0.01;
    },
    (f) => {
      f.phases[0].lastObservedAt -= 0.01;
    },
    (f) => {
      f.phases[0].maximumSourceGapSeconds = 0.1;
    },
    (f) => {
      f.phases[0].maximumObservationGapSeconds = 0;
    },
    (f) => {
      f.isClosed = false;
    },
    (f) => {
      f.invalid = true;
    },
    (f) => {
      f.formatVersion = 3;
    },
    (f) => {
      f.scope.recordingID = 'other';
    },
    (f) => {
      f.publishingGeneration = '2';
    },
  ];
  for (const change of changes) {
    const { format, snapshot } = fixture();
    change(format);
    assert.throws(() => qualifyNativeCompressedFrames(format, snapshot), change.toString());
  }
});
test('source gaps are retained honestly and half-open output bins do not infer continuous rate', () => {
  const { format, snapshot } = fixture();
  format.compressedFrames[1].sourcePTS = pts(1);
  // A source gap at the transition is allowed; exact phase endpoints still bind it.
  for (let n = 4; n < 12; n++) format.compressedFrames[n].sourcePTS = pts(n + 1);
  for (const p of [1, 2]) {
    format.phases[p].firstSourcePTS = pts(p * 4 + 1);
    format.phases[p].lastSourcePTS = pts(p * 4 + 4);
  }
  assert.equal(qualifyNativeCompressedFrames(format, snapshot).phases[1].syncFrames[0].frameID, 5);
});

test('paced evidence retains dequeue times and independently enforces source-cadence eligibility', () => {
  const { format, snapshot } = fixture();
  assert.throws(() =>
    qualifyNativeCompressedFrames(format, snapshot, { requirePacingEvidence: true }),
  );
  for (const r of format.compressedFrames) {
    r.dequeuedAt = r.observedAt - 0.001;
    r.sourceCadencePaced = true;
  }
  const result = qualifyNativeCompressedFrames(format, snapshot, { requirePacingEvidence: true });
  assert.equal(result.pacing.frames, 12);
  assert.ok(result.pacing.maximumWaitSeconds > 0);
  format.compressedFrames[2].dequeuedAt = format.compressedFrames[2].observedAt + 0.1;
  assert.throws(() => qualifyNativeCompressedFrames(format, snapshot));
});

test('pacing qualification rejects early output, excessive lead, mixed modes and invalid dequeue chronology', () => {
  for (const [mutate, reason] of [
    [
      (f) => {
        f.compressedFrames[1].observedAt = 100.02;
        f.compressedFrames[1].dequeuedAt = 100.01;
      },
      /ahead of source-cadence/,
    ],
    [
      (f) => {
        f.compressedFrames[1].sourcePTS = pts(40);
      },
      /one-second/,
    ],
    [
      (f) => {
        f.compressedFrames[1].sourceCadencePaced = false;
      },
      /mode changed/,
    ],
    [
      (f) => {
        delete f.compressedFrames[1].dequeuedAt;
      },
      /assert/,
    ],
    [
      (f) => {
        f.compressedFrames[1].dequeuedAt = 99.99;
      },
      /out of order/,
    ],
    [
      (f) => {
        f.compressedFrames[1].dequeuedAt = NaN;
      },
      /assert/,
    ],
  ]) {
    const { format, snapshot } = fixture();
    for (const r of format.compressedFrames) {
      r.dequeuedAt = r.observedAt - 0.001;
      r.sourceCadencePaced = true;
    }
    mutate(format);
    assert.throws(
      () => qualifyNativeCompressedFrames(format, snapshot, { requirePacingEvidence: true }),
      reason,
    );
  }
  const { format, snapshot } = fixture();
  for (const r of format.compressedFrames) {
    r.dequeuedAt = r.observedAt;
    r.sourceCadencePaced = false;
  }
  assert.equal(qualifyNativeCompressedFrames(format, snapshot).pacing.sourceCadencePaced, false);
  assert.throws(() =>
    qualifyNativeCompressedFrames(format, snapshot, { requirePacingEvidence: true }),
  );
});
