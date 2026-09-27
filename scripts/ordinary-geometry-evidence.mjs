import assert from 'node:assert/strict';
import {
  qualifyOrdinary720RecoveryNativeEvidence,
  qualifyPhysical720RecoveryNativeEvidence,
} from './ordinary-recovery-evidence.mjs';

function integer(value, minimum = 0, maximum = Number.MAX_SAFE_INTEGER) {
  assert(
    Number.isSafeInteger(value) && value >= minimum && value <= maximum,
    'Invalid geometry integer',
  );
  return value;
}
function ticks(value) {
  assert(
    typeof value === 'string' && /^(0|-?[1-9][0-9]*)$/.test(value),
    'Invalid native decoder PTS',
  );
  const n = BigInt(value);
  assert(n >= -9007199254740991n && n <= 9007199254740991n, 'Unsafe native decoder PTS');
  return n;
}
function bounded(row) {
  assert(
    row && typeof row === 'object' && Buffer.byteLength(JSON.stringify(row)) <= 4096,
    'Oversized worker record',
  );
}
/** Pre-scale decoded geometry only. Condensed runs bound endpoints; they do not
 * reconstruct interior PTS, measure frame freshness/latency, or prove capacity. */
export function qualifyOrdinary720GeometryEvidence(input) {
  return qualifyGeometry(input, qualifyOrdinary720RecoveryNativeEvidence(input));
}
/** Same geometry checks, with the separately versioned physical startup proof. */
export function qualifyPhysical720GeometryEvidence(input) {
  return qualifyGeometry(input, qualifyPhysical720RecoveryNativeEvidence(input));
}
function qualifyGeometry({ native, workerRows, expectedGameId, expectedGeneration }, qualified) {
  assert(
    typeof expectedGameId === 'string' && expectedGameId.length > 0 && expectedGameId.length <= 128,
  );
  integer(expectedGeneration, 1);
  assert(Array.isArray(workerRows), 'Worker rows required');
  const selected = qualified.phases.map(({ phase }) => {
    const milestone = native.milestones.find((m) => m.phase === phase);
    return { phase, diagnostic: native.samples[milestone.sampleIndex].diagnostic };
  });
  const pipelineReadKey = selected[0].diagnostic.policyPipelineReadKey;
  assert(
    typeof pipelineReadKey === 'string' && /^[a-f0-9]{64}$/.test(pipelineReadKey),
    'Missing pipeline read key',
  );
  for (const { diagnostic } of selected)
    assert.equal(diagnostic.policyPipelineReadKey, pipelineReadKey, 'Native read identity changed');
  const rows = workerRows.filter(
    (row) =>
      row?.pipelineReadKey === pipelineReadKey &&
      ['worker_decoded_geometry', 'worker_pipeline_terminal'].includes(row.msg),
  );
  assert(rows.length >= 2 && rows.length <= 65, 'Incomplete or unbounded geometry records');
  const terminals = rows.filter((row) => row.msg === 'worker_pipeline_terminal');
  assert.equal(terminals.length, 1, 'Exactly one matching terminal required');
  const terminal = terminals[0],
    pipelineOrdinal = integer(terminal.pipelineOrdinal, 1);
  for (const row of rows) {
    bounded(row);
    assert.equal(row.gameId, expectedGameId);
    assert.equal(row.generation, expectedGeneration);
    assert.equal(row.pipelineOrdinal, pipelineOrdinal, 'Multiple pipeline terminal scopes');
  }
  assert.equal(terminal.telemetryEOF, true, 'Decoder telemetry drain missing');
  const exit = terminal.encoderExit;
  assert(
    exit &&
      ((Number.isInteger(exit.code) &&
        exit.code >= 0 &&
        exit.code <= 255 &&
        exit.signal === null) ||
        (exit.code === null && typeof exit.signal === 'string' && /^SIG[A-Z]+$/.test(exit.signal))),
    'Actual encoder exit missing',
  );
  assert.equal(terminal.diagnostics?.ended, true, 'Stderr drain missing');
  assert.equal(terminal.diagnostics.pipeError, false);
  assert.equal(terminal.diagnostics.drainTimedOut, false);
  assert.equal(terminal.diagnostics.incompleteLine, false);
  const runs = rows
    .filter((row) => row.msg === 'worker_decoded_geometry')
    .sort((a, b) => a.runIndex - b.runIndex);
  const total = integer(runs[0].observedFrames, 1);
  let frames = 0;
  for (let i = 0; i < runs.length; i++) {
    const r = runs[i];
    assert.equal(r.formatVersion, 1);
    assert.equal(r.diagnosticOnly, true);
    assert.equal(r.timeBase, '1/90000');
    assert.equal(r.maximumRuns, 64);
    assert.equal(r.ended, true);
    assert.equal(r.invalidReason, null);
    assert.equal(r.observedFrames, total);
    assert.equal(r.runCount, runs.length);
    assert.equal(r.runIndex, i);
    integer(r.width, 2, 7680);
    integer(r.height, 2, 4320);
    assert(r.width % 2 === 0 && r.height % 2 === 0);
    integer(r.firstOrdinal);
    integer(r.lastOrdinal);
    integer(r.frames, 1);
    integer(r.maximumPTSDelta);
    integer(r.firstPTS, -Number.MAX_SAFE_INTEGER);
    integer(r.lastPTS, -Number.MAX_SAFE_INTEGER);
    assert.equal(r.firstOrdinal, frames, 'Noncontiguous geometry ordinal');
    assert.equal(r.lastOrdinal - r.firstOrdinal + 1, r.frames, 'Geometry run count mismatch');
    frames = integer(frames + r.frames);
    const span = BigInt(r.lastPTS) - BigInt(r.firstPTS);
    if (r.frames === 1) {
      assert.equal(span, 0n);
      assert.equal(r.maximumPTSDelta, 0);
    } else {
      assert(span >= BigInt(r.frames - 1), 'Nonincreasing geometry PTS');
      assert(r.maximumPTSDelta > 0 && BigInt(r.maximumPTSDelta) <= span);
      assert(BigInt(r.maximumPTSDelta) * BigInt(r.frames - 1) >= span, 'Invalid maximum PTS delta');
    }
    if (i) {
      assert(r.firstPTS > runs[i - 1].lastPTS, 'Geometry boundary PTS rewind');
      assert(
        r.width !== runs[i - 1].width || r.height !== runs[i - 1].height,
        'Adjacent identical runs were not contiguous',
      );
    }
  }
  assert.equal(frames, total, 'Geometry lifetime count mismatch');
  const decoded = terminal.decodedVideo;
  assert(
    decoded &&
      decoded.timeBase === '1/90000' &&
      decoded.ended === true &&
      decoded.invalidReason === null,
  );
  assert.equal(decoded.acceptedFrames, total);
  assert.equal(decoded.freshFrames, total);
  assert.equal(decoded.duplicateFrames, 0);
  assert.equal(decoded.reorderedFrames, 0);
  assert.equal(decoded.firstPTS, runs[0].firstPTS);
  assert.equal(decoded.lastPTS, runs.at(-1).lastPTS);
  assert.equal(decoded.highestPTS, runs.at(-1).lastPTS);
  const phases = selected.map(({ phase, diagnostic: d }) => {
    const previous = ticks(d.policyDecodedPreviousPTS),
      first = ticks(d.policyDecodedFirstPTS),
      last = ticks(d.policyDecodedLastPTS);
    const count = ticks(d.policyDecodedFrameCount);
    assert(
      previous < first && first <= last && count > 0n && last - first >= count - 1n,
      'Invalid native decoder window',
    );
    assert((count === 1n) === (first === last));
    const runIndex = runs.findIndex(
      (r) => first >= BigInt(r.firstPTS) && last <= BigInt(r.lastPTS),
    );
    assert(runIndex >= 0, 'Native window spans geometry runs');
    const run = runs[runIndex],
      dimensions = { '240p30': [426, 240], '360p30': [640, 360], '720p30': [1280, 720] }[
        d.policyAppliedProfile
      ];
    assert.deepEqual(
      [run.width, run.height],
      dimensions,
      'Decoded dimensions differ from native profile',
    );
    assert(count <= BigInt(run.frames), 'Native window exceeds geometry run count');
    if (first === BigInt(run.firstPTS) && last === BigInt(run.lastPTS))
      assert.equal(count, BigInt(run.frames));
    // If the exclusive anchor precedes this run, it must exclude the known last
    // decoded frame in the prior run. No interior frame timestamps are invented.
    if (previous < BigInt(run.firstPTS)) {
      assert.equal(first, BigInt(run.firstPTS), 'Native window omitted known first boundary frame');
      if (runIndex)
        assert(
          previous >= BigInt(runs[runIndex - 1].lastPTS),
          'Native window includes previous geometry run',
        );
    }
    return {
      phase,
      runIndex,
      width: run.width,
      height: run.height,
      previousPTS: d.policyDecodedPreviousPTS,
      firstPTS: d.policyDecodedFirstPTS,
      lastPTS: d.policyDecodedLastPTS,
      frames: Number(count),
    };
  });
  return {
    geometryQualified: true,
    nativePhaseOrderingQualified: true,
    transportQualified: false,
    mediaQualified: false,
    pipelineReadKey,
    gameId: expectedGameId,
    generation: expectedGeneration,
    pipelineOrdinal,
    observedFrames: total,
    phases,
  };
}
