import test from 'node:test';
import assert from 'node:assert/strict';
import {
  physicalRecordingIdentity,
  requireNativeExportReport,
  qualifyCombinedNativeEvidence,
  qualifyCombinedGeometry,
  qualifyCombinedResources,
  requirePhysicalQualificationResult,
} from '../physical-qualification-evidence.mjs';
const id = '33D2FF99-7918-42EA-8D41-9A5C076B2011';
function nativeFixture() {
  const samples = Array.from({ length: 21 }, (_, i) => ({
    phase:
      i === 0
        ? 'confirmed1080-hold-started'
        : i === 20
          ? 'confirmed1080-hold-complete'
          : 'confirmed1080-hold',
    readStartedUptimeSeconds: 100 + i * 30,
    readEndedUptimeSeconds: 100 + i * 30 + 0.1,
    diagnostic: {
      sessionObservedAtUptimeSeconds: String(100 + i * 30),
      observedAtUptimeSeconds: String(100 + i * 30),
      policyOwnerKey: 'a'.repeat(64),
      policySourceScopeKey: 'b'.repeat(64),
      policyPipelineReadKey: 'c'.repeat(64),
      policyAttemptID: id.toLowerCase(),
      policyAppliedRevision: '3',
      policyAcknowledgedAtUptimeSeconds: '90',
      policyAppliedProfile: '1080p30',
      policyAppliedBitrate: '6000000',
      sessionClosed: 'false',
      driverClosed: 'false',
      sessionBusy: 'false',
      policyRecommendationPending: 'false',
      policyApplicationPending: 'false',
      policyMinimumResetRequired: 'false',
      policyTrialActive: 'false',
      policyTrialRollbackRequired: 'false',
      policyAcceptedSourceSequence: String(i + 1),
      policyAcceptedSourceWindowEnd: String(99 + i * 30),
      policyDecodedFirstPTS: String(i * 30 * 90000),
      policyDecodedLastPTS: String((i * 30 + 4) * 90000),
    },
  }));
  return {
    contract: 'physical-combined4k1080-v1',
    confirmed1080HoldSeconds: 600,
    captureSource: 'physical-camera',
    failure: null,
    samples,
    milestones: [
      { phase: 'confirmed1080-hold-started', sampleIndex: 0, uptimeSeconds: 100.1 },
      { phase: 'confirmed1080-hold-complete', sampleIndex: 20, uptimeSeconds: 700.2 },
      { phase: 'recording-stop-requested', uptimeSeconds: 712 },
      { phase: 'export-ready', uptimeSeconds: 800 },
    ],
  };
}
test('export collection chooses exact recording identity and rejects a stale or foreign export', () => {
  assert.equal(physicalRecordingIdentity([{ phase: 'export-ready', recordingID: id }]), id);
  assert.throws(() =>
    physicalRecordingIdentity(
      [{ phase: 'export-ready', recordingID: id }],
      '00000000-0000-0000-0000-000000000000',
    ),
  );
  assert.throws(() =>
    physicalRecordingIdentity([
      { phase: 'export-ready', recordingID: id },
      { phase: 'playback-advanced', recordingID: '00000000-0000-0000-0000-000000000000' },
    ]),
  );
  const r = {
    contract: 'scorebug-native-export-v1',
    recordingID: id,
    fileName: `${id}-11111111-1111-1111-1111-111111111111.mp4`,
    bytes: 100,
    videoFrames: 100,
    audioSamples: 100,
    duration: 10,
    completedUptimeSeconds: 800,
    fullDecodeCompleted: true,
  };
  assert.equal(requireNativeExportReport(r, id), r);
  for (const bad of [
    { fileName: '../export.mp4' },
    { bytes: 0 },
    { fullDecodeCompleted: false },
    { recordingID: id.toLowerCase() },
  ])
    assert.throws(() => requireNativeExportReport({ ...r, ...bad }, id));
});
test('hold rejects startup time, downgraded geometry, stale proof and changed authority', () => {
  const n = nativeFixture();
  const h = qualifyCombinedNativeEvidence(n, 600);
  assert.equal(h.samples, 21);
  for (const mutate of [
    (n) => (n.milestones[1].uptimeSeconds = 650),
    (n) => (n.samples[10].diagnostic.policyAppliedProfile = '720p30'),
    (n) => (n.samples[10].diagnostic.sessionObservedAtUptimeSeconds = '100'),
    (n) => (n.samples[10].diagnostic.policyOwnerKey = 'd'.repeat(64)),
    (n) => n.samples.splice(10, 1),
    (n) => (n.failure = 'downgrade'),
    (n) => n.samples.forEach((s) => delete s.diagnostic.policyAttemptID),
    (n) => n.samples.forEach((s) => (s.diagnostic.policyAppliedRevision = '')),
    (n) => n.samples.forEach((s) => (s.diagnostic.policyAcknowledgedAtUptimeSeconds = '9999')),
    (n) => (n.milestones[0].uptimeSeconds = 130),
    (n) => (n.milestones[1].uptimeSeconds = 900),
  ]) {
    const f = structuredClone(n);
    mutate(f);
    assert.throws(() => qualifyCombinedNativeEvidence(f, 600));
  }
});
test('pre-scale geometry must enclose the entire hold with actual1080 input', () => {
  const h = qualifyCombinedNativeEvidence(nativeFixture(), 600);
  const g = {
    pipelineReadKey: h.pipelineReadKey,
    msg: 'worker_decoded_geometry',
    ended: true,
    invalidReason: null,
    runIndex: 0,
    runCount: 1,
    timeBase: '1/90000',
    pipelineOrdinal: 1,
    firstOrdinal: 0,
    lastOrdinal: 18300,
    frames: 18301,
    firstPTS: 0,
    lastPTS: 610 * 90000,
    width: 1920,
    height: 1080,
    maximumPTSDelta: 3000,
  };
  const t = {
    pipelineReadKey: h.pipelineReadKey,
    msg: 'worker_pipeline_terminal',
    pipelineOrdinal: 1,
    telemetryEOF: true,
    diagnostics: { ended: true },
    decodedVideo: {
      ended: true,
      invalidReason: null,
      duplicateFrames: 0,
      reorderedFrames: 0,
      acceptedFrames: 18301,
      freshFrames: 18301,
      firstPTS: 0,
      lastPTS: 610 * 90000,
    },
  };
  assert.equal(qualifyCombinedGeometry([g, t], h).frames, 18301);
  for (const bad of [{ width: 1280, height: 720 }, { lastPTS: 590 * 90000 }, { frames: 18000 }])
    assert.throws(() => qualifyCombinedGeometry([{ ...g, ...bad }, t], h));
});
test('resources reject missing samples, camera pressure and thermal fallback without guessing a memory ceiling', () => {
  const hold = { holdSeconds: 600, startUptimeSeconds: 100, endUptimeSeconds: 700 };
  const r = {
    recordingID: id,
    closed: true,
    overflow: false,
    archiveWidth: 3840,
    archiveHeight: 2160,
    archiveFPS: 30,
    rows: Array.from({ length: 63 }, (_, i) => ({
      uptimeSeconds: 90 + i * 10,
      thermalState: 0,
      physicalFootprintBytes: 100000000 + i * 100,
      processCPUSeconds: i * 2,
      batteryState: 2,
      capture: {
        videoFrames: i * 300,
        cameraPressureLevel: 'nominal',
        frameWasLate: 0,
        outOfBuffers: 0,
        discontinuity: 0,
        unknownDrops: 0,
      },
    })),
  };
  assert.equal(qualifyCombinedResources(r, id, hold).drops, 0);
  const jittered = structuredClone(r);
  jittered.rows = jittered.rows
    .slice(0, 59)
    .map((row, i) => ({ ...row, uptimeSeconds: 95 + i * 10.5 }));
  assert.equal(qualifyCombinedResources(jittered, id, hold).drops, 0);
  for (const mutate of [
    (r) => (r.rows[20].thermalState = 2),
    (r) => (r.rows[20].capture.cameraPressureLevel = 'serious'),
    (r) => (r.rows[20].physicalFootprintBytes = null),
    (r) => r.rows.splice(20, 3),
    (r) => (r.overflow = true),
    (r) => (r.rows[20].processCPUSeconds = 0),
    (r) => (r.rows[20].capture.videoFrames = 0),
    (r) => (r.rows[20].capture.unknownDrops = 10),
    (r) => (r.rows[20].capture.outOfBuffers = -1),
    (r) => (r.rows[20].capture.frameWasLate = null),
  ]) {
    const f = structuredClone(r);
    mutate(f);
    assert.throws(() => qualifyCombinedResources(f, id, hold));
  }
});

test('a failed native export or collection fails archive-stop as well as combined qualification', () => {
  const complete = { gates: { nativeExport: true }, archive: '/qa/export.mp4' };
  assert.equal(requirePhysicalQualificationResult(complete, 'archive-stop'), complete);
  for (const report of [
    { failure: 'copy failed', gates: { nativeExport: true } },
    { gates: { nativeExport: false } },
    { gates: { nativeExport: true } },
  ]) {
    assert.throws(() => requirePhysicalQualificationResult(report, 'archive-stop'));
  }
  assert.throws(() => requirePhysicalQualificationResult(complete, 'combined1080'));
});
