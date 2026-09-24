import { deliverySnapshot } from '../../../packages/protocol/dist/index.js';
import {
  repeatedMeasuredRecoveryFaultFixture,
  repeatedFaultDeliveryRow,
} from './repeated-measured-recovery-fault-evidence.mjs';

const processingID = 'eeeeeeee-eeee-4eee-8eee-000000000001';
/** Synthetic policy component fixture. Raw pressure/cadence/deadline artifacts
 * are replayed; source/media and admission summaries remain explicit external
 * contracts. It retains the original five encoder phases and global revisions. */
export function repeatedMeasuredPolicyFixture(
  base = repeatedMeasuredRecoveryFaultFixture(),
  { recoveryDeliverySeconds = 10, captureBoundaryJitter = false } = {},
) {
  const f = base;
  const original = f.quality.events;
  const boot = original[0],
    apps = original.filter((e) => e.kind === 'applied'),
    candidates = original.filter((e) => e.kind === 'candidate');
  const triggers = original.filter((e) => ['decoderStall', 'deliveryFailure'].includes(e.kind));
  const template = structuredClone(f.cadenceReports.rows[0]);
  const publication = template.response.status.publication;
  const oldReports = f.cadenceReports.rows;
  f.snapshot.sourceIntervals = [];
  f.sourceIntervalQualification = { scope: f.scope, intervals: [] };
  f.quality.events = [boot, ...apps, ...candidates, ...triggers, original.at(-1)];
  f.cadenceReports.rows = [];
  f.deliveryAudit ??= {
    formatVersion: 2,
    mode: 'repeated',
    maximumRows: 512,
    maximumBytes: 33554432,
    closed: true,
    invalid: false,
    overflow: false,
    latencyBudget: 1.5,
    maximumSampleAge: 0.25,
    rows: [],
  };
  let sourceSequence = 1,
    policySequence = 0;
  const policyReports = [];
  function sourceEvent(
    configuration,
    start,
    end,
    { transition = false, confirm = false, delayed = false, last = false } = {},
  ) {
    const sequence = String(++sourceSequence),
      previousSequence = String(sourceSequence - 1),
      firstFrame = Math.round((start - 100) * 30),
      lastFrame = Math.round((end - 100) * 30),
      captured = lastFrame - firstFrame,
      decoded = captured - (last ? 1 : 0),
      lastPTS = (lastFrame - (last ? 1 : 0)) * 3000;
    const processing = {
      encoder: 'videotoolbox',
      scopeID: processingID,
      sequence: sourceSequence,
      previousSequence: sourceSequence - 1,
      firstPTS: (firstFrame + 1) * 3000,
      interval: {
        sourceStartExclusive: firstFrame * 3000,
        sourceEndInclusive: lastPTS,
        decodedFrames: decoded,
        submittedFrames: decoded,
        completedFrames: decoded,
        pendingFrames: 0,
        omittedBeforeEncoderFrames: 0,
        filterDuration: { meanMs: 1, maximumMs: 2 },
        processingDuration: { meanMs: 1, maximumMs: 2 },
      },
    };
    const source = {
      scope: f.scope,
      sequence,
      previousSequence,
      workerId: template.response.status.workerId,
      workerEpoch: template.response.status.workerEpoch,
      workerAttempt: 1,
      publication: structuredClone(publication),
      publishingGeneration: configuration.receipt.generation,
      encodingConfiguration: {
        id: configuration.receipt.configurationID,
        encoderSessionID: configuration.receipt.encoderSessionID,
        bitRate: configuration.receipt.bitRate,
      },
      previousDecodedPTS: String(firstFrame * 3000),
      firstDecodedPTS: String((firstFrame + 1) * 3000),
      lastDecodedPTS: String(lastPTS),
      sourceStartExclusive: f.format.compressedFrames[firstFrame].sourcePTS,
      sourceEndInclusive: f.format.compressedFrames[lastFrame].sourcePTS,
      captureBoundaryStartTime: start,
      captureBoundaryEndTime: end,
      capturedFrames: captured,
      encodedFrames: captured,
      decodedFrames: decoded,
      captureNotEncodedFrames: 0,
      encodedNotDecodedFrames: captured - decoded,
      leadingMissingEncodedFrames: 0,
      processing,
    };
    f.snapshot.sourceIntervals.push(source);
    f.sourceIntervalQualification.intervals.push({
      sequence: sourceSequence,
      previousSequence: sourceSequence - 1,
      sourceStartExclusive: firstFrame,
      sourceEndInclusive: lastFrame,
      capturedFrames: captured,
      encodedFrames: captured,
      decodedFrames: decoded,
      captureNotEncodedFrames: 0,
      encodedNotDecodedFrames: captured - decoded,
      leadingMissingEncodedFrames: 0,
    });
    const evaluatedAt = delayed ? end + 1.9 : end + 0.2;
    const row = {
      ...structuredClone(configuration),
      kind: transition ? 'transition' : 'evaluated',
      at: evaluatedAt + 0.01,
      evaluatedAt,
      closed: false,
      source: {
        sequence,
        previousSequence,
        start,
        end,
        attemptID: f.scope.publishingAttemptID,
        workerID: source.workerId,
        workerEpoch: source.workerEpoch,
        workerAttempt: 1,
        readerID: publication.readerId,
        processingScopeID: processingID,
      },
      reasons: transition ? [] : ['missingCapacity', ...(confirm ? ['trialConfirmed'] : [])],
      state: 'healthy',
    };
    if (!transition) {
      if (
        Number(configuration.revision) % 2 === 1 &&
        end <= 145 + (Number(configuration.revision) - 1) * 30
      )
        row.state = confirm ? 'unknown' : 'probing';
      row.window = {
        revision: configuration.revision,
        sequence: String(++policySequence),
        start,
        end,
        observedAt: evaluatedAt - 0.01,
        captured,
        encoded: captured,
        received: decoded,
        expected: captured,
        lost: captured - decoded,
        capacity: null,
        connectivity: 'connected',
        queue: 0.1,
        thermal: 'nominal',
        worker: 'nominal',
        transport: 'nominal',
      };
      const steps = Math.ceil((end - start) / 1.5);
      const times = Array.from(
        { length: steps + 1 },
        (_, i) => start + ((end - start) * i) / steps,
      );
      row.evidence = {
        thermal: {
          isClosed: false,
          isQuarantined: false,
          samples: times.map((sampledAt) => ({ sampledAt, state: 0 })),
        },
        transport: {
          isClosed: false,
          isQuarantined: false,
          samples: times.map((sampledAt) => ({
            sampledAt,
            generation: configuration.receipt.generation,
            elapsedMilliseconds: String(Math.round(sampledAt * 1000)),
            sentBytes: String(Math.round(sampledAt * 10000)),
            retransmittedBytes: '0',
            droppedPackets: 0,
            senderBufferMilliseconds: 0,
            rttMilliseconds: 10,
            senderDeliveryDelayMilliseconds: 100,
          })),
        },
        queue: {
          isClosed: false,
          isQuarantined: false,
          scope: f.scope,
          coveredThrough: end,
          states: [{ at: start, itemFraction: 0.1, byteFraction: 0.1, phase: 'admitting' }],
        },
        processing: structuredClone(processing),
      };
      const report = structuredClone(template);
      report.evaluatedUptime = evaluatedAt - 0.01;
      report.receivedUptime = evaluatedAt - 0.02;
      report.response.status.observation.decodedVideo.completed = {
        sequence: sourceSequence,
        firstPTS: Number(source.firstDecodedPTS),
        lastPTS,
        freshFrames: decoded,
        valid: true,
      };
      report.response.status.observation.processing = { scopeID: processingID };
      policyReports.push(report);
    }
    f.quality.events.push(row);
  }
  function windows(configuration, points, options = {}) {
    for (let i = 1; i < points.length; i++)
      sourceEvent(configuration, points[i - 1], points[i], i === points.length - 1 ? options : {});
  }
  windows(boot, [104, 109, 112, 117, 122, 124, 129]);
  for (let i = 0; i < 2; i++) {
    const shift = i * 60,
      trial = apps[i * 2],
      reset = apps[i * 2 + 1],
      candidate = candidates[i];
    trial.application.windowSequence = String(policySequence);
    const c = candidate.candidate,
      w = candidate.candidateAdmission;
    w.measurement ??= { id: c.id };
    w.measurement.startedAt ??= c.measuredStart;
    w.measurement.endedAt ??= c.measuredEnd;
    for (const [key, value] of Object.entries({
      evaluatedAt: c.evaluatedAt,
      validUntil: c.validUntil,
      candidateTransportBitsPerSecond: 600000,
      deliveredPaddingBitsPerSecond: 1000000,
    })) {
      w[key] ??= value;
      c[key] ??= w[key];
    }
    trial.action.validUntil = Math.min(c.validUntil, 129 + shift + 2, 129 + shift + 0.19 + 2);
    candidate.application = structuredClone(trial.application);
    candidate.action = structuredClone(trial.action);
    sourceEvent(trial, 129 + shift, 131 + shift, { transition: true });
    windows(
      trial,
      [131, 136, 140, 145].map((n) => n + shift),
      { confirm: true },
    );
    const trigger = triggers[i],
      deliveryFirst = trigger.kind === 'deliveryFailure',
      bridgeEnd = deliveryFirst ? 157.2 : 100 + 1760 / 30,
      signal = trigger.decoderStall ?? trigger.deliveryFailure;
    windows(
      trial,
      (deliveryFirst ? [145, 150, 152.2, bridgeEnd] : [145, 150, 154, bridgeEnd]).map(
        (n) => n + shift,
      ),
      deliveryFirst ? { delayed: true, last: true } : {},
    );
    signal.sequence = String(++policySequence);
    reset.application.windowSequence = signal.sequence;
    const pts = ((deliveryFirst ? 1715 : 1760) + i * 1800) * 3000;
    if (trigger.decoderStall) trigger.decoderStall.lastFreshPTS = String(pts);
    for (const sample of [
      f.faults.campaigns[i].beforePauseSample,
      f.faults.campaigns[i].pausedSample,
    ])
      sample.value.decoderCadence.progress.lastFreshPTS = pts;
    sourceEvent(reset, bridgeEnd + shift, 161 + shift, { transition: true });
    windows(
      reset,
      i === 0 ? [161, 166, 171, 172, 177, 182, 184, 189] : [221, 226, 231, 236, 241, 246],
    );
  }
  f.quality.events.sort((a, b) => a.at - b.at);
  for (const row of f.quality.events) {
    const configuration = [boot, ...apps].find((e) => e.revision === row.revision);
    for (const key of ['application', 'receipt', 'profileReceipt', 'acknowledgedAt'])
      if (configuration[key] !== undefined) row[key] = structuredClone(configuration[key]);
  }
  for (let i = 0; i < 2; i++) {
    const index = f.quality.events.findIndex(
      (e) =>
        e.kind === 'evaluated' &&
        e.revision === String(i * 2 + 1) &&
        e.reasons.includes('trialConfirmed'),
    );
    f.faults.campaigns[i].confirmedEventIndex = index;
  }
  f.candidateWitnessQualifications = candidates.map((c, i) => ({
    campaign: String(i + 1),
    appliedRevision: String(i * 2),
    candidateID: c.candidate.id,
    ...structuredClone(c.candidateAdmission),
  }));
  // Explicit native lifecycle dependency contract, retaining original request and receipts.
  f.lifecycleQualification = {
    scope: f.scope,
    bootstrap: structuredClone(boot),
    applications: apps.map((app, i) => ({
      applicationID: app.application.id,
      candidateID: app.application.candidateID,
      target: app.profileID,
      requestedAt: f.lifecycle.profileRequests[i].requestedAt,
      application: structuredClone(app.application),
      receipt: structuredClone(app.receipt),
      profileReceipt: structuredClone(app.profileReceipt),
      acknowledgedAt: app.acknowledgedAt,
    })),
  };
  const deliveryReports = [];
  for (const [revision, start] of [
    ['2', 161],
    ['4', 221],
  ])
    for (const duration of [1, 2])
      for (let at = start; at < start + recoveryDeliverySeconds; at += duration) {
        // Builder reads the cadence owner from rows[0].
        f.cadenceReports.rows = [template];
        const { row, report } = repeatedFaultDeliveryRow(f, {
          captureBoundaryJitter,
          revision,
          start: at,
          end: at + duration,
          evaluatedAt: at + duration + 1.7,
        });
        // Both lanes evaluated together use the same current HTTP snapshot.
        report.deliveryReceiptID = `eeeeeeee-eeee-4eee-8eee-${String(Math.round(row.end * 1000)).padStart(12, '0')}`;
        row.deliveryReceiptID = report.deliveryReceiptID;
        f.deliveryAudit.rows.push(row);
        deliveryReports.push(report);
      }
  f.deliveryAudit.rows.sort(
    (a, b) => a.evaluatedAt - b.evaluatedAt || a.end - a.start - (b.end - b.start),
  );
  const byTime = new Map();
  const put = (r) => byTime.set(Math.round(r.evaluatedUptime * 1e6), r);
  for (let t = 104; t <= 249; t += 0.25) {
    const r = structuredClone(template);
    r.evaluatedUptime = t;
    r.receivedUptime = t - 0.01;
    put(r);
  }
  for (const report of policyReports) put(report);
  for (const report of deliveryReports) put(report);
  for (let i = 0; i < 2; i++) {
    const shift = i * 60;
    for (const source of oldReports.filter(
      (r) => r.evaluatedUptime >= 158.6 + shift && r.evaluatedUptime <= 160.4 + shift,
    )) {
      const r = structuredClone(source);
      delete r.response.status.observation.decodedVideo.completed;
      delete r.response.status.observation.processing;
      put(r);
    }
    // Keep the original helper times, and add the first actual resumed sample
    // after the owned1.8s pause ends at native160.8/220.8.
    const resumed = structuredClone(template);
    resumed.evaluatedUptime = 160.81 + shift;
    resumed.receivedUptime = 160.8 + shift;
    put(resumed);
    // Avoid an unused helper observed between the actual trigger report and decision.
    for (const [key, r] of byTime)
      if (r.evaluatedUptime > 159.88 + shift && r.evaluatedUptime <= 159.9 + shift)
        byTime.delete(key);
  }
  f.cadenceReports.rows = [...byTime.values()].sort(
    (a, b) => a.evaluatedUptime - b.evaluatedUptime,
  );
  // One explicit native-time arrival schedule drives every cadence snapshot
  // and raw deadline packet. Delivery-first slows before the pause: its last
  // frame arrives at158.97 despite capture at157.167, producing real lateness.
  // Decoder-first arrives normally through frame1760, then stops. Queued frames
  // resume at160.8; native resumption observations occur at160.81.
  const arrivalAt = (frame) => {
    let at = 100 + frame / 30 + 0.1;
    for (let i = 0; i < 2; i++) {
      const shift = i * 60,
        frameShift = i * 1800,
        deliveryFirst = triggers[i].kind === 'deliveryFailure',
        paused = (deliveryFirst ? 1715 : 1760) + frameShift;
      if (deliveryFirst && frame >= 1566 + frameShift && frame <= paused)
        at = 152.3 + shift + ((frame - 1566 - frameShift) * (158.97 - 152.3)) / (1715 - 1566);
      if (frame > paused) at = Math.max(at, 160.8 + shift);
    }
    return at;
  };
  // These synthetic Node timestamps share one known offset to native uptime.
  // Reconstruct sample ages under that fixture-only clock mapping; production
  // qualification continues to use separate conservative clock domains.
  for (let i = 0; i < 2; i++) {
    const fault = f.faults.campaigns[i];
    fault.resumeSentAt = fault.pauseSentAt + 1800;
    for (const sample of [fault.beforePauseSample, fault.pausedSample]) {
      const progress = sample.value.decoderCadence.progress;
      const snapshotNativeAt = sample.receivedAt / 1000 + 59 - 0.01;
      progress.ageMs = (snapshotNativeAt - arrivalAt(progress.lastFreshPTS / 3000)) * 1000;
      progress.stalled = progress.ageMs >= 1000;
    }
  }
  for (const report of f.cadenceReports.rows) {
    // Snapshot age is bounded by20ms. Use the exact synthetic packet sample
    // when present, otherwise10ms before evaluation. Production replay uses
    // only exported bounds and never assumes this synthetic clock alignment.
    const packet = report.response.status.observation.decoderDelivery;
    const snapshotAt = packet ? packet.sampledAtMs / 1000 : report.evaluatedUptime - 0.01;
    let frame = 0;
    while (frame + 1 < f.format.compressedFrames.length && arrivalAt(frame + 1) <= snapshotAt)
      frame++;
    if (packet) {
      // Retain the independently captured packet's original ordinal coverage.
      // Its cadence sample belongs to that same packet and decoder progress.
      frame = packet.lastOrdinal - 1;
      for (const arrival of packet.arrivals) arrival[1] = arrivalAt(arrival[0] / 3000) * 1000;
      packet.coverageAtMs = packet.afterOrdinal ? arrivalAt(packet.afterOrdinal - 1) * 1000 : 0;
      for (const row of f.deliveryAudit.rows)
        if (row.deliveryReceiptID === report.deliveryReceiptID)
          row.timeline = deliverySnapshot(packet);
    }
    const ageMs = (snapshotAt - arrivalAt(frame)) * 1000;
    Object.assign(report.response.status.observation.decoderCadence.progress, {
      lastFreshPTS: frame * 3000,
      ageMs,
      stalled: ageMs >= 1000,
    });
    report.observedStall = ageMs >= 1000;
  }
  // Recompute the failure lane from its actual delayed packet arrivals rather
  // than preserving the previous synthetic on-time counts or decision labels.
  for (const trigger of triggers) {
    if (trigger.kind !== 'deliveryFailure') continue;
    const signal = trigger.deliveryFailure;
    const row = f.deliveryAudit.rows.find((r) => r.deliveryReceiptID === signal.deliveryReceiptID);
    const report = f.cadenceReports.rows.find(
      (r) => r.deliveryReceiptID === signal.deliveryReceiptID,
    );
    const arrivals = new Map(
      report.response.status.observation.decoderDelivery.arrivals.map(([pts, at]) => [
        String(pts),
        at / 1000,
      ]),
    );
    let onTimeFrames = 0,
      lateFrames = 0,
      missingFrames = 0;
    for (const frame of row.frames) {
      const at = arrivals.get(frame.pts);
      if (at === undefined) missingFrames++;
      else if (at <= frame.capturedAt + 1.5) onTimeFrames++;
      else lateFrames++;
    }
    Object.assign(row.result, {
      onTimeFrames,
      lateFrames,
      missingFrames,
      onTimeFPS: onTimeFrames / (row.end - row.start),
      failureFraction: (lateFrames + missingFrames) / row.frames.length,
    });
    Object.assign(signal, { onTimeFrames, lateFrames, missingFrames });
    trigger.state = onTimeFrames === 0 ? 'stalled' : 'degraded';
    trigger.reasons = ['freshFrameFloor', ...(onTimeFrames === 0 ? ['stalled'] : [])];
  }
  delete f.confirmations;
  return f;
}

/** A source export can outlive quality consumption during shutdown. These are
 * explicit independently qualified component source contracts, without policy
 * decisions, pressure evidence, or any additional health credit. */
export function appendRepeatedPolicyShutdownSource(f, duration = 1.5) {
  const previous = f.snapshot.sourceIntervals.at(-1),
    source = structuredClone(previous),
    start = previous.captureBoundaryEndTime,
    end = start + duration,
    startFrame = Math.round((start - 100) * 30),
    endFrame = Math.round((end - 100) * 30),
    count = endFrame - startFrame;
  Object.assign(source, {
    sequence: String(Number(previous.sequence) + 1),
    previousSequence: previous.sequence,
    captureBoundaryStartTime: start,
    captureBoundaryEndTime: end,
    sourceStartExclusive: f.format.compressedFrames[startFrame].sourcePTS,
    sourceEndInclusive: f.format.compressedFrames[endFrame].sourcePTS,
    previousDecodedPTS: String(startFrame * 3000),
    firstDecodedPTS: String((startFrame + 1) * 3000),
    lastDecodedPTS: String(endFrame * 3000),
    capturedFrames: count,
    encodedFrames: count,
    decodedFrames: count,
    captureNotEncodedFrames: 0,
    encodedNotDecodedFrames: 0,
    leadingMissingEncodedFrames: 0,
  });
  Object.assign(source.processing, {
    sequence: Number(source.sequence),
    previousSequence: Number(source.previousSequence),
    firstPTS: Number(source.firstDecodedPTS),
  });
  Object.assign(source.processing.interval, {
    sourceStartExclusive: Number(source.previousDecodedPTS),
    sourceEndInclusive: Number(source.lastDecodedPTS),
    decodedFrames: count,
    submittedFrames: count,
    completedFrames: count,
  });
  f.snapshot.sourceIntervals.push(source);
  f.sourceIntervalQualification.intervals.push({
    sequence: Number(source.sequence),
    previousSequence: Number(source.previousSequence),
    sourceStartExclusive: startFrame,
    sourceEndInclusive: endFrame,
    capturedFrames: count,
    encodedFrames: count,
    decodedFrames: count,
    captureNotEncodedFrames: 0,
    encodedNotDecodedFrames: 0,
    leadingMissingEncodedFrames: 0,
  });
  return f;
}
