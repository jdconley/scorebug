import assert from 'node:assert/strict';
import { ordinarySourceAgeLimit } from './ordinary-recovery-evidence.mjs';
const uuid = /^[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}$/;
const key = /^[a-f0-9]{64}$/;
function finite(n) {
  assert(Number.isFinite(n) && n >= 0, 'Invalid native uptime');
  return n;
}
function scalar(s) {
  assert(typeof s === 'string' && s.trim() === s && s !== '', 'Missing native scalar');
  return finite(Number(s));
}
/** Exact completed export identity only; never choose by newest file or row order. */
export function physicalRecordingIdentity(reports, expectedID) {
  const ids = reports
    .filter((r) =>
      [
        'export-ready',
        'playback-advanced',
        'completed-after-relaunch',
        'recoverable-after-relaunch',
        'new-hardware-recording-export-ready',
      ].includes(r.phase),
    )
    .map((r) => r.recordingID);
  assert(
    ids.length >= 1 && ids.every((id) => uuid.test(id ?? '')),
    'Missing completed recording identity',
  );
  assert(new Set(ids).size === 1, 'Multiple export identities in the same workflow');
  if (expectedID !== undefined)
    assert.equal(ids[0], expectedID, 'Saved export selected another recording');
  return ids[0];
}
export function requireNativeExportReport(report, recordingID) {
  assert(uuid.test(recordingID));
  assert.equal(report.contract, 'scorebug-native-export-v1');
  assert.equal(report.recordingID, recordingID);
  assert.equal(report.fullDecodeCompleted, true);
  assert(
    new RegExp(`^${recordingID}-[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}\\.mp4$`).test(
      report.fileName,
    ),
    'Unsafe or foreign export filename',
  );
  for (const field of ['bytes', 'videoFrames', 'audioSamples'])
    assert(Number.isSafeInteger(report[field]) && report[field] > 0, `Invalid native ${field}`);
  finite(report.completedUptimeSeconds);
  assert(finite(report.duration) > 0);
  return report;
}
/** Confirmed native hold with bounded fresh proof; actual input geometry, saved
 * media, resources and environmental configuration remain independent gates. */
export function qualifyCombinedNativeEvidence(native, holdSeconds) {
  assert([600, 1800, 3600].includes(holdSeconds));
  assert.equal(native.contract, 'physical-combined4k1080-v1');
  assert.equal(native.confirmed1080HoldSeconds, holdSeconds);
  assert.equal(native.captureSource, 'physical-camera');
  assert(native.failure == null, 'Native workflow reported a failed gate');
  assert(Array.isArray(native.samples) && native.samples.length <= 512);
  const milestone = (phase) => {
    const matches = native.milestones.filter((m) => m.phase === phase);
    assert.equal(matches.length, 1, `Missing/duplicate ${phase}`);
    finite(matches[0].uptimeSeconds);
    return matches[0];
  };
  const start = milestone('confirmed1080-hold-started'),
    end = milestone('confirmed1080-hold-complete');
  assert(
    end.uptimeSeconds - start.uptimeSeconds >= holdSeconds,
    'Hold included unconfirmed startup time',
  );
  const selected = native.samples.filter((s) =>
    ['confirmed1080-hold-started', 'confirmed1080-hold', 'confirmed1080-hold-complete'].includes(
      s.phase,
    ),
  );
  assert(selected.length >= Math.floor(holdSeconds / 30) + 1, 'Incomplete hold proof sampling');
  assert.equal(native.samples[start.sampleIndex], selected[0]);
  assert.equal(native.samples[end.sampleIndex], selected.at(-1));
  for (const [milestone, sample] of [
    [start, selected[0]],
    [end, selected.at(-1)],
  ]) {
    const readEnd = finite(sample.readEndedUptimeSeconds);
    assert(
      milestone.uptimeSeconds >= readEnd && milestone.uptimeSeconds - readEnd <= 5,
      'Hold milestone detached from its fresh read',
    );
  }
  const baseline = selected[0].diagnostic;
  assert(uuid.test((baseline.policyAttemptID ?? '').toUpperCase()), 'Missing attempt identity');
  const revision = scalar(baseline.policyAppliedRevision);
  assert(Number.isSafeInteger(revision) && revision > 0, 'Invalid application revision');
  const acknowledged = scalar(baseline.policyAcknowledgedAtUptimeSeconds);
  let lastEnd = 0,
    lastSequence = -1,
    lastWindow = 0;
  for (const sample of selected) {
    const d = sample.diagnostic,
      readStart = finite(sample.readStartedUptimeSeconds),
      readEnd = finite(sample.readEndedUptimeSeconds);
    assert(
      readStart >= lastEnd && readEnd >= readStart && readEnd - readStart <= 5,
      'Invalid native read bracket',
    );
    if (lastEnd) assert(readStart - lastEnd <= 40, 'Missing hold observations');
    const observed = scalar(d.sessionObservedAtUptimeSeconds),
      driver = scalar(d.observedAtUptimeSeconds);
    assert(
      observed <= driver && driver <= readEnd && readEnd - observed <= 5,
      'Stale native session',
    );
    assert(acknowledged <= observed, 'Acknowledgment is newer than observed session');
    for (const field of ['policyOwnerKey', 'policySourceScopeKey', 'policyPipelineReadKey']) {
      assert(key.test(d[field] ?? ''), 'Missing source ownership');
      assert.equal(d[field], baseline[field], 'Hold ownership changed');
    }
    for (const field of [
      'policyAttemptID',
      'policyAppliedRevision',
      'policyAcknowledgedAtUptimeSeconds',
    ])
      assert.equal(d[field], baseline[field], 'Hold application changed');
    assert.equal(d.policyAppliedProfile, '1080p30');
    assert.equal(d.policyAppliedBitrate, '6000000');
    for (const field of [
      'sessionClosed',
      'driverClosed',
      'sessionBusy',
      'policyRecommendationPending',
      'policyApplicationPending',
      'policyMinimumResetRequired',
      'policyTrialActive',
    ])
      assert.equal(d[field], 'false', `Unsettled hold: ${field}`);
    assert.notEqual(d.policyTrialRollbackRequired, 'true');
    const sequence = scalar(d.policyAcceptedSourceSequence),
      window = scalar(d.policyAcceptedSourceWindowEnd);
    assert(
      Number.isSafeInteger(sequence) &&
        sequence >= lastSequence &&
        window >= lastWindow &&
        window <= observed &&
        observed - window <= ordinarySourceAgeLimit(d),
      'Stale or regressing source window',
    );
    lastEnd = readEnd;
    lastSequence = sequence;
    lastWindow = window;
  }
  assert(milestone('recording-stop-requested').uptimeSeconds >= end.uptimeSeconds);
  assert(milestone('export-ready').uptimeSeconds > end.uptimeSeconds);
  return {
    holdSeconds,
    startUptimeSeconds: start.uptimeSeconds,
    endUptimeSeconds: end.uptimeSeconds,
    samples: selected.length,
    attemptID: baseline.policyAttemptID,
    pipelineReadKey: baseline.policyPipelineReadKey,
    appliedRevision: baseline.policyAppliedRevision,
    firstDecodedPTS: selected[0].diagnostic.policyDecodedFirstPTS,
    lastDecodedPTS: selected.at(-1).diagnostic.policyDecodedLastPTS,
  };
}
export function qualifyCombinedGeometry(workerRows, hold) {
  const rows = workerRows.filter((r) => r.pipelineReadKey === hold.pipelineReadKey);
  const terminals = rows.filter((r) => r.msg === 'worker_pipeline_terminal');
  assert.equal(terminals.length, 1, 'Exactly one source pipeline terminal required');
  const terminal = terminals[0],
    decoded = terminal.decodedVideo;
  assert(
    terminal.telemetryEOF &&
      terminal.diagnostics?.ended &&
      !terminal.diagnostics.pipeError &&
      !terminal.diagnostics.drainTimedOut &&
      !terminal.diagnostics.incompleteLine,
    'Incomplete worker diagnostic drain',
  );
  assert(
    decoded?.ended &&
      decoded.invalidReason === null &&
      decoded.duplicateFrames === 0 &&
      decoded.reorderedFrames === 0 &&
      decoded.acceptedFrames === decoded.freshFrames,
    'Invalid lifetime source cadence',
  );
  const runs = rows
    .filter((r) => r.msg === 'worker_decoded_geometry')
    .sort((a, b) => a.runIndex - b.runIndex);
  assert(runs.length >= 1 && runs.length <= 64);
  let total = 0;
  for (const [index, run] of runs.entries()) {
    assert(
      run.ended &&
        run.invalidReason === null &&
        run.runIndex === index &&
        run.runCount === runs.length &&
        run.timeBase === '1/90000',
    );
    assert.equal(run.pipelineOrdinal, terminal.pipelineOrdinal);
    assert.equal(run.gameId, terminal.gameId);
    assert.equal(run.generation, terminal.generation);
    assert.equal(run.firstOrdinal, total);
    assert.equal(run.lastOrdinal - run.firstOrdinal + 1, run.frames);
    for (const field of ['firstPTS', 'lastPTS', 'frames', 'maximumPTSDelta'])
      assert(
        Number.isSafeInteger(run[field]) &&
          (['firstPTS', 'lastPTS'].includes(field) || run[field] >= 0),
      );
    assert(
      run.frames > 0 &&
        run.lastPTS >= run.firstPTS &&
        (index === 0 || run.firstPTS > runs[index - 1].lastPTS),
    );
    total += run.frames;
  }
  assert.equal(total, decoded.acceptedFrames);
  assert.equal(decoded.firstPTS, runs[0].firstPTS);
  assert.equal(decoded.lastPTS, runs.at(-1).lastPTS);
  const first = Number(hold.firstDecodedPTS),
    last = Number(hold.lastDecodedPTS);
  assert(
    Number.isSafeInteger(first) && Number.isSafeInteger(last) && first < last,
    'Missing native source coordinates',
  );
  const run = runs.find((r) => r.firstPTS <= first && r.lastPTS >= last);
  assert(
    run && run.width === 1920 && run.height === 1080,
    'Hold crossed a different input geometry',
  );
  const duration = (run.lastPTS - run.firstPTS) / 90000;
  assert(duration >= hold.holdSeconds, 'Actual1080 input span is shorter than the hold');
  const expected = Math.round(duration * 30) + 1;
  assert(run.frames >= expected * 0.99, 'Actual1080 source loss exceeded1%');
  return {
    width: 1920,
    height: 1080,
    frames: run.frames,
    sourceDurationSeconds: duration,
    maximumPTSDelta: run.maximumPTSDelta,
    pipelineOrdinal: run.pipelineOrdinal,
  };
}
export function qualifyCombinedResources(report, recordingID, hold) {
  assert.equal(report.recordingID, recordingID);
  assert.equal(report.closed, true);
  assert.equal(report.overflow, false);
  assert.equal(report.archiveWidth, 3840);
  assert.equal(report.archiveHeight, 2160);
  assert.equal(report.archiveFPS, 30);
  assert(Array.isArray(report.rows) && report.rows.length <= 512);
  const rows = report.rows.filter(
    (r) =>
      r.uptimeSeconds >= hold.startUptimeSeconds - 10 &&
      r.uptimeSeconds <= hold.endUptimeSeconds + 10,
  );
  assert(rows.length >= Math.floor(hold.holdSeconds / 15) + 1, 'Missing capture resource sampling');
  assert(
    rows[0].uptimeSeconds <= hold.startUptimeSeconds &&
      rows.at(-1).uptimeSeconds >= hold.endUptimeSeconds,
    'Resource samples do not enclose the hold',
  );
  let last = 0,
    previous;
  const counterKeys = [
    'videoFrames',
    'frameWasLate',
    'outOfBuffers',
    'discontinuity',
    'unknownDrops',
  ];
  for (const row of rows) {
    finite(row.uptimeSeconds);
    assert(row.uptimeSeconds > last && (!last || row.uptimeSeconds - last <= 15));
    last = row.uptimeSeconds;
    assert([0, 1].includes(row.thermalState), 'Serious, critical or unavailable thermal state');
    assert(
      ['nominal', 'fair'].includes(row.capture?.cameraPressureLevel),
      'Elevated or unavailable camera pressure',
    );
    assert(
      Number.isSafeInteger(row.physicalFootprintBytes) && row.physicalFootprintBytes > 0,
      'Missing physical memory measurement',
    );
    finite(row.processCPUSeconds);
    assert(
      !previous || row.processCPUSeconds >= previous.processCPUSeconds,
      'Regressing process CPU measurement',
    );
    for (const field of counterKeys) {
      const value = row.capture[field];
      assert(
        Number.isSafeInteger(value) &&
          value >= 0 &&
          (!previous || value >= previous.capture[field]),
        'Missing or regressing capture counter',
      );
    }
    previous = row;
  }
  const a = rows[0],
    b = rows.at(-1),
    video = b.capture.videoFrames - a.capture.videoFrames;
  const drops = ['frameWasLate', 'outOfBuffers', 'discontinuity', 'unknownDrops'].reduce(
    (sum, key) => sum + b.capture[key] - a.capture[key],
    0,
  );
  assert(
    Number.isSafeInteger(video) &&
      video >= 24 * hold.holdSeconds &&
      Number.isSafeInteger(drops) &&
      drops >= 0 &&
      drops / (video + drops) < 0.01,
    'Capture delivery/drop budget failed',
  );
  const elapsed = b.uptimeSeconds - a.uptimeSeconds;
  return {
    samples: rows.length,
    maximumPhysicalFootprintBytes: Math.max(...rows.map((r) => r.physicalFootprintBytes)),
    footprintGrowthBytes: b.physicalFootprintBytes - a.physicalFootprintBytes,
    averageProcessCPUCores: (b.processCPUSeconds - a.processCPUSeconds) / elapsed,
    videoFrames: video,
    drops,
    thermalStates: [...new Set(rows.map((r) => r.thermalState))],
    batteryStates: [...new Set(rows.map((r) => r.batteryState))],
  };
}

export function requirePhysicalQualificationResult(report, lane) {
  const valid =
    lane === 'combined1080'
      ? report.encoded1080HoldQualified === true
      : lane === 'archive-stop' &&
        report.gates.nativeExport === true &&
        typeof report.archive === 'string';
  if (report.failure || !valid) {
    throw Object.assign(new Error(report.failure ?? 'Physical qualification failed'), {
      qualification: report,
    });
  }
  return report;
}
