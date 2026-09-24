import { deliverySnapshot } from '../../../packages/protocol/dist/index.js';
import { repeatedLifecycleFixture } from './repeated-lifecycle-evidence.mjs';
import { qualifyNativeProfileTransitions } from '../../native-profile-transitions.mjs';
import { fixtureFrameID } from '../../video-observation-qualification.mjs';

const id = (n) => `dddddddd-dddd-4ddd-8ddd-${String(n).padStart(12, '0')}`;
/** Synthetic component contracts only: confirms/faults use one original global
 * five-phase history. Source/confirmation summaries are explicit dependencies;
 * this fixture does not claim complete policy or real hardware qualification. */
export function repeatedMeasuredRecoveryFaultFixture(base = repeatedLifecycleFixture()) {
  const f = structuredClone(base);
  f.archiveIDs = f.format.compressedFrames.map((r) => fixtureFrameID(r.sourcePTS));
  f.profileQualification = qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, {
    sequence: 'repeated240',
    requireFrameEvidence: true,
  });
  f.sourceIntervalQualification = { scope: f.scope, intervals: [] };
  f.snapshot.sourceIntervals = [];
  f.quality.decoderStallEnabled = true;
  f.quality.deadlineFailuresEnabled = true;
  const publication = {
    readerId: id(1),
    publisherId: id(2),
    publishingAttemptId: f.scope.publishingAttemptID.toLowerCase(),
    clock: { convention: 'mpegts-ingress-origin-90k-v1', originPTS: '9000' },
  };
  const owner = {
    gameId: f.scope.matchID,
    generation: f.scope.broadcastGeneration,
    workerId: 'worker',
    workerEpoch: id(3),
    attempt: 1,
    publication,
  };
  const cadence = (pts, age) => ({
    formatVersion: 1,
    scopeID: id(4),
    ended: false,
    invalidReason: null,
    progress: { lastFreshPTS: pts, ageMs: age, stalled: age >= 1000 },
  });
  const report = (at, pts, age) => ({
    expectedAttempt: publication.publishingAttemptId,
    receivedUptime: at - 0.01,
    evaluatedUptime: at,
    requestSeconds: 0.01,
    residenceSeconds: 0.01,
    sampleAgeSeconds: 0.02,
    observedStall: age >= 1000,
    deliveryReceiptID: null,
    deliverySampleAgeSeconds: null,
    response: {
      serverTime: '2040-01-01T00:00:00.000Z',
      status: {
        ...structuredClone(owner),
        state: 'producing_output',
        expiresAt: '2040-01-01T00:00:05.000Z',
        decoderCadenceAgeUpperBoundMs: 0,
        observation: {
          gameId: f.scope.matchID,
          generation: f.scope.broadcastGeneration,
          state: 'producing_output',
          attempt: 1,
          decodedVideo: { clock: 'mpegts-pts-90k-v1' },
          decoderCadence: cadence(pts, age),
        },
      },
    },
  });
  const workerSample = (requestStartedAt, receivedAt, pts, age) => ({
    requestStartedAt,
    receivedAt,
    value: {
      context: structuredClone(owner),
      serverTime: '2040-01-01T00:00:00.000Z',
      expiresAt: '2040-01-01T00:00:05.000Z',
      decoderCadenceAgeUpperBoundMs: 5,
      decoderCadence: cadence(pts, age),
    },
  });
  const identity = {
    worker: { pid: 10, ppid: 1, start: '2040-01-01T00:00:00Z', command: '/bin/node' },
    guardian: { pid: 11, ppid: 10, start: '2040-01-01T00:00:01Z', command: '/bin/node' },
    decoder: { pid: 12, ppid: 11, start: '2040-01-01T00:00:02Z', command: '/bin/ffmpeg' },
  };
  f.cadenceReports = {
    formatVersion: 2,
    mode: 'repeated',
    maximumRows: 3072,
    maximumBytes: 16777216,
    closed: true,
    invalid: false,
    overflow: false,
    rows: [],
  };
  f.faults = {
    formatVersion: 2,
    mode: 'repeated',
    closed: true,
    failed: false,
    scope: f.scope,
    campaigns: [],
  };
  f.confirmations = [];
  for (let index = 0; index < 2; index++) {
    const offset = index * 60,
      revision = String(index * 2 + 1),
      campaign = String(index + 1);
    const trial = f.quality.events.find((e) => e.kind === 'applied' && e.revision === revision);
    const reset = f.quality.events.find(
      (e) => e.kind === 'applied' && e.revision === String(index * 2 + 2),
    );
    const confirmed = {
      ...structuredClone(trial),
      kind: 'evaluated',
      at: 145.11 + offset,
      evaluatedAt: 145.1 + offset,
      reasons: ['missingCapacity', 'trialConfirmed'],
      state: 'healthy',
      window: { end: 145 + offset },
      source: { sequence: String(index * 12 + 8) },
    };
    const pts = (1760 + index * 1800) * 3000;
    const trigger = {
      ...structuredClone(trial),
      kind: 'decoderStall',
      at: 159.91 + offset,
      evaluatedAt: 159.9 + offset,
      reasons: ['stalled'],
      state: 'stalled',
      decoderStall: {
        scopeID: id(4),
        workerID: owner.workerId,
        workerEpoch: owner.workerEpoch,
        workerAttempt: 1,
        readerID: publication.readerId,
        publishingAttemptID: publication.publishingAttemptId,
        lastFreshPTS: String(pts),
        sequence: String(index * 12 + 10),
        revision,
        observedAtLowerBound: 159.86 + offset,
      },
    };
    delete trigger.action;
    reset.action.validUntil = trigger.decoderStall.observedAtLowerBound + 0.25;
    reset.application.windowSequence = trigger.decoderStall.sequence;
    f.quality.events.push(confirmed, trigger);
    f.cadenceReports.rows.push(
      report(158.7 + offset, pts, 10),
      report(159.88 + offset, pts, 1200),
      report(160.3 + offset, pts + 3000, 10),
    );
    const startFrame = 1740 + index * 1800,
      endFrame = 1770 + index * 1800;
    const source = {
      scope: f.scope,
      sequence: String(index * 12 + 9),
      previousSequence: String(index * 12 + 8),
      workerId: owner.workerId,
      workerEpoch: owner.workerEpoch,
      workerAttempt: 1,
      publication: structuredClone(publication),
      previousDecodedPTS: String(startFrame * 3000),
      lastDecodedPTS: String(endFrame * 3000),
      sourceStartExclusive: f.format.compressedFrames[startFrame].sourcePTS,
      sourceEndInclusive: f.format.compressedFrames[endFrame].sourcePTS,
      captureBoundaryStartTime: 158 + offset,
      captureBoundaryEndTime: 159 + offset,
      capturedFrames: 30,
      encodedFrames: 30,
      decodedFrames: 30,
      captureNotEncodedFrames: 0,
      encodedNotDecodedFrames: 0,
      leadingMissingEncodedFrames: 0,
    };
    f.snapshot.sourceIntervals.push(source);
    f.sourceIntervalQualification.intervals.push({
      sequence: Number(source.sequence),
      previousSequence: Number(source.previousSequence),
      sourceStartExclusive: startFrame,
      sourceEndInclusive: endFrame,
      ...Object.fromEntries(
        [
          'capturedFrames',
          'encodedFrames',
          'decodedFrames',
          'captureNotEncodedFrames',
          'encodedNotDecodedFrames',
          'leadingMissingEncodedFrames',
        ].map((k) => [k, source[k]]),
      ),
    });
    const pauseSentAt = 100000 + index * 60000;
    f.faults.campaigns.push({
      campaign,
      candidateID: trial.application.candidateID,
      trialRevision: revision,
      closed: true,
      failed: false,
      identity: structuredClone(identity),
      pauseSentAt,
      resumeSentAt: pauseSentAt + 2000,
      beforePauseSample: workerSample(pauseSentAt - 20, pauseSentAt - 10, pts, 10),
      pausedSample: workerSample(pauseSentAt + 1200, pauseSentAt + 1210, pts, 1200),
    });
    f.confirmations.push({
      campaign,
      appliedRevision: String(index * 2),
      trialRevision: revision,
      proofExtent: 'confirmed-prefix',
      confirmed: 1,
      confirmedAt: confirmed.evaluatedAt,
      confirmedEventAt: confirmed.at,
      probation: { start: 135 + offset, end: 145 + offset, coverageSeconds: 10 },
    });
  }
  const last = f.quality.events.find((e) => e.kind === 'applied' && e.revision === '4');
  f.quality.events.push({ ...structuredClone(last), kind: 'stopped', at: 252, closed: true });
  f.quality.events.sort((a, b) => a.at - b.at);
  for (let index = 0; index < 2; index++) {
    const p = f.confirmations[index];
    p.confirmedEventIndex = f.quality.events.findIndex(
      (e) => e.kind === 'evaluated' && e.revision === p.trialRevision,
    );
    p.nextEventIndex = p.confirmedEventIndex + 1;
    p.rawEventCount = f.quality.events.length;
    f.faults.campaigns[index].confirmedEventIndex = p.confirmedEventIndex;
  }
  return f;
}

/** Bounded raw deadline row/report builder for this synthetic 100s media clock.
 * Missing deliveries stop at lastDecodedFrame; otherwise arrivals are capture+100ms.
 * The caller retains all rows on the original global report/deadline timelines. */
export function repeatedFaultDeliveryRow(
  f,
  {
    revision,
    start,
    end,
    evaluatedAt,
    lastDecodedFrame = Math.floor((evaluatedAt - 100 - 0.15) * 30),
    cadenceAgeMs = 10,
  },
) {
  const event = f.quality.events.find(
    (e) => (e.kind === 'applied' || e.kind === 'bootstrap') && e.revision === revision,
  );
  const r = event.receipt;
  const configuration = {
    id: r.configurationID.toLowerCase(),
    encoderSessionID: r.encoderSessionID.toLowerCase(),
    bitRate: r.bitRate,
  };
  const receipt = {
    generation: r.generation,
    configuration,
    acceptedAt: r.acceptedAt,
    lastSubmittedPTS: r.lastSubmittedPTS,
  };
  const clock = { generation: r.generation, sourceOrigin: f.format.compressedFrames[0].sourcePTS };
  const packetBase = Math.max(0, lastDecodedFrame + 1 - 256),
    sampledAtMs = (evaluatedAt - 0.04) * 1000;
  const packet = {
    formatVersion: 1,
    scopeID: id(5),
    sampledAtMs,
    coverageAtMs: packetBase ? (100 + (packetBase - 1) / 30 + 0.1) * 1000 : 0,
    afterOrdinal: packetBase,
    lastOrdinal: lastDecodedFrame + 1,
    arrivals: Array.from({ length: lastDecodedFrame + 1 - packetBase }, (_, i) => {
      const frame = packetBase + i;
      return [frame * 3000, (100 + frame / 30 + 0.1) * 1000];
    }),
    invalidReason: null,
    ended: false,
  };
  const report = structuredClone(f.cadenceReports.rows[0]);
  Object.assign(report, {
    receivedUptime: evaluatedAt - 0.03,
    evaluatedUptime: evaluatedAt - 0.02,
    requestSeconds: 0.01,
    residenceSeconds: 0.01,
    sampleAgeSeconds: 0.02,
    deliveryReceiptID: id(1000 + Math.round(start * 1000)),
    deliverySampleAgeSeconds: 0.02,
    observedStall: cadenceAgeMs >= 1000,
  });
  const status = report.response.status;
  status.decoderDeliveryAgeUpperBoundMs = 0;
  status.observation.decoderDelivery = packet;
  status.observation.decoderCadence.progress = {
    lastFreshPTS: lastDecodedFrame * 3000,
    ageMs: cadenceAgeMs,
    stalled: cadenceAgeMs >= 1000,
  };
  const context = {
    gameId: status.gameId,
    generation: status.generation,
    workerId: status.workerId,
    workerEpoch: status.workerEpoch,
    attempt: status.observation.attempt,
    publication: structuredClone(status.publication),
  };
  const first = Math.floor((start - 100) * 30) - 1,
    last = Math.max(Math.ceil((end - 100) * 30), lastDecodedFrame) + 1;
  const capture = Array.from({ length: last - first + 1 }, (_, i) => {
    const frame = first + i;
    return {
      sourcePTS: f.format.compressedFrames[frame].sourcePTS,
      observedAt: 100 + frame / 30,
      encoding: null,
    };
  });
  const encoded = capture.map((c) => ({
    ...structuredClone(c),
    observedAt: c.observedAt + 0.002,
    encoding: {
      encoderSessionID: configuration.encoderSessionID,
      configuration: structuredClone(configuration),
      submittedAt: c.observedAt + 0.001,
      completedAt: c.observedAt + 0.002,
    },
  }));
  const frames = capture
    .filter((c) => c.observedAt >= start && c.observedAt < end)
    .map((c) => ({
      pts: String(fixtureFrameID(c.sourcePTS) * 3000),
      sourcePTS: c.sourcePTS,
      capturedAt: c.observedAt,
      wasEncoded: true,
    }));
  const onTimeFrames = frames.filter((c) => Number(c.pts) <= lastDecodedFrame * 3000).length,
    missingFrames = frames.length - onTimeFrames;
  const row = {
    phase: Number(revision) + 1,
    start,
    end,
    evaluatedAt,
    appliedRevision: revision,
    acknowledgedAt: event.acknowledgedAt,
    profileID: event.profileID,
    videoBitrate: r.bitRate,
    attemptID: f.scope.publishingAttemptID.toLowerCase(),
    receipt,
    deliveryReceiptID: report.deliveryReceiptID,
    sampleAgeSeconds: 0.04,
    clock,
    clockClosed: false,
    clockScope: f.scope,
    history: {
      scope: f.scope,
      closed: false,
      invalidity: null,
      omittedCaptureFrames: '0',
      omittedEncodedFrames: '0',
      trimmedCaptureFrames: 0,
      trimmedEncodedFrames: 0,
      capture,
      encoded,
    },
    timeline: deliverySnapshot(packet),
    context,
    diagnostics: {
      isPublishing: true,
      clock,
      receipt,
      ingressScope: f.scope,
      ingressClosed: false,
    },
    anchorSourcePTS: f.format.compressedFrames[lastDecodedFrame].sourcePTS,
    frames,
    reason: null,
    result: {
      expectedFrames: frames.length,
      onTimeFrames,
      lateFrames: 0,
      missingFrames,
      uncertainFrames: 0,
      onTimeFPS: onTimeFrames / (end - start),
      failureFraction: missingFrames / frames.length,
    },
  };
  return { row, report };
}

export function repeatedMeasuredDeliveryFaultFixture(
  routes = ['deliveryFailure', 'deliveryFailure'],
  base = repeatedMeasuredRecoveryFaultFixture(),
) {
  const f = structuredClone(base);
  f.deliveryAudit = {
    formatVersion: 1,
    closed: true,
    overflow: false,
    invalid: false,
    latencyBudget: 1.5,
    maximumSampleAge: 0.25,
    rows: [],
  };
  for (let index = 0; index < 2; index++) {
    if (routes[index] !== 'deliveryFailure') continue;
    const offset = index * 60,
      revision = String(index * 2 + 1),
      lastDecodedFrame = 1715 + index * 1800,
      pts = lastDecodedFrame * 3000;
    const trigger = f.quality.events.find(
      (e) => e.kind === 'decoderStall' && e.revision === revision,
    );
    const { row, report } = repeatedFaultDeliveryRow(f, {
      revision,
      start: 157 + offset,
      end: 158 + offset,
      evaluatedAt: 159.9 + offset,
      lastDecodedFrame,
      cadenceAgeMs: 900,
    });
    const old = trigger.decoderStall;
    trigger.kind = 'deliveryFailure';
    trigger.state = 'degraded';
    trigger.reasons = ['freshFrameFloor'];
    trigger.deliveryFailure = {
      classifiedAt: row.evaluatedAt,
      deliveryReceiptID: row.deliveryReceiptID,
      scopeID: row.timeline.scopeID,
      context: structuredClone(row.context),
      publishingAttemptID: f.scope.publishingAttemptID.toLowerCase(),
      sequence: old.sequence,
      revision,
      start: row.start,
      end: row.end,
      expectedFrames: row.result.expectedFrames,
      onTimeFrames: row.result.onTimeFrames,
      lateFrames: 0,
      missingFrames: row.result.missingFrames,
      observedAtLowerBound: row.evaluatedAt - row.sampleAgeSeconds,
    };
    delete trigger.decoderStall;
    const reset = f.quality.events.find(
      (e) => e.kind === 'applied' && e.revision === String(index * 2 + 2),
    );
    reset.action.validUntil = Math.min(
      row.end + 2,
      trigger.deliveryFailure.observedAtLowerBound + 0.25,
    );
    trigger.action = structuredClone(reset.action);
    const first = f.cadenceReports.rows.find(
      (r) => Math.abs(r.evaluatedUptime - (158.7 + offset)) < 1e-6,
    );
    first.response.status.observation.decoderCadence.progress.lastFreshPTS = pts;
    const reportIndex = f.cadenceReports.rows.findIndex(
      (r) => Math.abs(r.evaluatedUptime - (159.88 + offset)) < 1e-6,
    );
    f.cadenceReports.rows[reportIndex] = report;
    const stalled = structuredClone(report);
    Object.assign(stalled, {
      receivedUptime: 159.99 + offset,
      evaluatedUptime: 160 + offset,
      deliveryReceiptID: null,
      deliverySampleAgeSeconds: null,
      observedStall: true,
    });
    delete stalled.response.status.observation.decoderDelivery;
    Object.assign(stalled.response.status.observation.decoderCadence.progress, {
      ageMs: 1100,
      stalled: true,
    });
    f.cadenceReports.rows.push(stalled);
    const resumed = f.cadenceReports.rows.find(
      (r) => Math.abs(r.evaluatedUptime - (160.3 + offset)) < 1e-6,
    );
    resumed.response.status.observation.decoderCadence.progress.lastFreshPTS = pts + 3000;
    const source = f.snapshot.sourceIntervals[index],
      summary = f.sourceIntervalQualification.intervals[index],
      startFrame = 1680 + index * 1800,
      endFrame = 1740 + index * 1800;
    Object.assign(source, {
      previousDecodedPTS: String(startFrame * 3000),
      lastDecodedPTS: String(endFrame * 3000),
      sourceStartExclusive: f.format.compressedFrames[startFrame].sourcePTS,
      sourceEndInclusive: f.format.compressedFrames[endFrame].sourcePTS,
      captureBoundaryStartTime: 156 + offset,
      captureBoundaryEndTime: 158 + offset,
      capturedFrames: 60,
      encodedFrames: 60,
      decodedFrames: 60,
    });
    Object.assign(summary, {
      sourceStartExclusive: startFrame,
      sourceEndInclusive: endFrame,
      capturedFrames: 60,
      encodedFrames: 60,
      decodedFrames: 60,
    });
    for (const sample of [
      f.faults.campaigns[index].beforePauseSample,
      f.faults.campaigns[index].pausedSample,
    ])
      sample.value.decoderCadence.progress.lastFreshPTS = pts;
    f.deliveryAudit.rows.push(row);
  }
  f.cadenceReports.rows.sort((a, b) => a.evaluatedUptime - b.evaluatedUptime);
  return f;
}
