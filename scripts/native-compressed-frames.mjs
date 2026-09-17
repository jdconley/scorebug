import assert from 'node:assert/strict';
import { fixtureFrameID } from './video-observation-qualification.mjs';

// Diagnostic pre-mux evidence only. It cannot qualify delivery or network capacity.
export function qualifyNativeCompressedFrames(
  format,
  snapshot,
  { requirePacingEvidence = false, sequence = '1' } = {},
) {
  assert.ok(['1', 'low240', 'stall540'].includes(sequence));
  if (sequence === 'low240' || sequence === 'stall540') {
    assert.equal(format.formatVersion, sequence === 'stall540' ? 7 : 6);
    assert.equal(format.sequence, sequence);
  } else {
    assert.ok(format.formatVersion === 4 || format.formatVersion === 5);
    assert.equal(format.sequence, undefined);
  }
  assert.equal(format.isClosed, true);
  assert.equal(format.invalid, false);
  assert.equal(snapshot.isClosed, true);
  assert.deepEqual(format.scope, snapshot.scope);
  assert.equal(
    format.publishingGeneration,
    snapshot.publishingClockObservation.publishingGeneration,
  );
  assert.match(format.publishingGeneration, /^[1-9]\d*$/);
  assert.ok(Number.isFinite(snapshot.monotonicAnchor) && snapshot.monotonicAnchor >= 0);
  assert.ok(
    Number.isFinite(snapshot.captureDetachedAt) &&
      snapshot.captureDetachedAt > snapshot.monotonicAnchor,
  );
  assert.ok(Number.isSafeInteger(format.frames) && format.frames > 0 && format.frames <= 25000);
  assert.ok(Array.isArray(format.compressedFrames));
  assert.equal(format.compressedFrames.length, format.frames);
  assert.ok(
    Array.isArray(format.phases) && format.phases.length >= 1 && format.phases.length <= 17,
  );
  const hasPacingEvidence = format.compressedFrames.some(
    (r) => r.dequeuedAt !== undefined || r.sourceCadencePaced !== undefined,
  );
  assert.ok(!requirePacingEvidence || hasPacingEvidence, 'Missing actual pacing observations');
  const first = format.compressedFrames[0];
  const paced = first.sourceCadencePaced;
  if (requirePacingEvidence) assert.equal(paced, true);
  let maximumWaitSeconds = 0,
    maximumSourceLeadSeconds = 0;
  const rows = format.compressedFrames.map((frame, n, all) => {
    const frameID = fixtureFrameID(frame.sourcePTS);
    assert.ok(Number.isSafeInteger(frame.byteCount) && frame.byteCount > 0);
    assert.equal(typeof frame.isSync, 'boolean');
    assert.ok(
      Number.isFinite(frame.observedAt) &&
        frame.observedAt >= snapshot.monotonicAnchor &&
        frame.observedAt <= snapshot.captureDetachedAt + 2,
    );
    if (hasPacingEvidence) {
      assert.equal(typeof frame.sourceCadencePaced, 'boolean');
      assert.equal(frame.sourceCadencePaced, paced, 'Pacing mode changed within publication');
      assert.ok(
        Number.isFinite(frame.dequeuedAt) &&
          frame.dequeuedAt >= snapshot.monotonicAnchor &&
          frame.dequeuedAt <= frame.observedAt,
      );
      if (n > 0)
        assert.ok(frame.dequeuedAt >= all[n - 1].observedAt, 'Consumer dequeued out of order');
      const due = first.dequeuedAt + (frameID - fixtureFrameID(first.sourcePTS)) / 30;
      const lead = due - frame.dequeuedAt;
      if (paced) {
        assert.ok(lead <= 1 + 1e-6, 'Source lead exceeds one-second pacing bound');
        assert.ok(
          frame.observedAt + 1e-6 >= due,
          'Frame emitted ahead of source-cadence eligibility',
        );
      }
      maximumWaitSeconds = Math.max(maximumWaitSeconds, frame.observedAt - frame.dequeuedAt);
      maximumSourceLeadSeconds = Math.max(maximumSourceLeadSeconds, lead);
    }
    if (n > 0) {
      assert.ok(
        frameID > fixtureFrameID(all[n - 1].sourcePTS),
        'Compressed source identities must increase',
      );
      assert.ok(frame.observedAt >= all[n - 1].observedAt, 'Compressed output clock reversed');
    }
    return {
      frameID,
      byteCount: frame.byteCount,
      isSync: frame.isSync,
      observedAt: frame.observedAt,
    };
  });
  let offset = 0,
    totalBytes = 0;
  const phases = format.phases.map((phase) => {
    assert.ok(
      Number.isSafeInteger(phase.frames) &&
        phase.frames > 0 &&
        offset + phase.frames <= rows.length,
    );
    const slice = rows.slice(offset, offset + phase.frames);
    offset += phase.frames;
    assert.equal(slice[0].frameID, fixtureFrameID(phase.firstSourcePTS));
    assert.equal(slice.at(-1).frameID, fixtureFrameID(phase.lastSourcePTS));
    assert.equal(slice[0].observedAt, phase.firstObservedAt);
    assert.equal(slice.at(-1).observedAt, phase.lastObservedAt);
    assert.equal(
      slice[0].isSync,
      true,
      'Every new encoder phase must start with native sync evidence',
    );
    let bytes = 0,
      maximumFrameBytes = 0,
      sourceGap = 0,
      observationGap = 0;
    const bins = new Map(),
      syncFrames = [];
    for (const [n, row] of slice.entries()) {
      bytes += row.byteCount;
      assert.ok(Number.isSafeInteger(bytes), 'Compressed byte total exceeds safe integer range');
      maximumFrameBytes = Math.max(maximumFrameBytes, row.byteCount);
      if (n > 0) {
        sourceGap = Math.max(sourceGap, (row.frameID - slice[n - 1].frameID) / 30);
        observationGap = Math.max(observationGap, row.observedAt - slice[n - 1].observedAt);
      }
      if (row.isSync)
        syncFrames.push({
          frameID: row.frameID,
          byteCount: row.byteCount,
          observedAt: row.observedAt,
        });
      // Phase-relative half-open intervals of the actual observer clock, not media PTS.
      const index = Math.floor((row.observedAt - phase.firstObservedAt) * 10);
      const bin = bins.get(index) ?? { index, bytes: 0, frames: 0 };
      bin.bytes += row.byteCount;
      bin.frames += 1;
      bins.set(index, bin);
    }
    assert.ok(
      Number.isFinite(phase.maximumSourceGapSeconds) &&
        Math.abs(sourceGap - phase.maximumSourceGapSeconds) <= 1e-9,
    );
    assert.ok(
      Number.isFinite(phase.maximumObservationGapSeconds) &&
        Math.abs(observationGap - phase.maximumObservationGapSeconds) <= 1e-9,
    );
    totalBytes += bytes;
    assert.ok(Number.isSafeInteger(totalBytes));
    return {
      frames: slice.length,
      totalBytes: bytes,
      maximumFrameBytes,
      syncFrames,
      peak100ms: [...bins.values()].reduce((largest, bin) =>
        bin.bytes > largest.bytes ? bin : largest,
      ),
    };
  });
  assert.equal(
    offset,
    rows.length,
    'Every compressed record must belong to exactly one native phase',
  );
  return {
    ...(hasPacingEvidence
      ? {
          pacing: {
            frames: rows.length,
            sourceCadencePaced: paced,
            maximumWaitSeconds,
            maximumSourceLeadSeconds,
          },
        }
      : {}),
    frames: rows.length,
    totalBytes,
    phases,
    note: 'Pre-mux sample bytes and native sync metadata; no receiver delivery or usable network capacity is inferred.',
  };
}
