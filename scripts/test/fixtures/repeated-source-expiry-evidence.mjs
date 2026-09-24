import assert from 'node:assert/strict';
import { repeatedMeasuredPolicyFixture } from './repeated-measured-policy-evidence.mjs';

/** Timestamp-backed component fixture; source/media proofs remain independently
 * supplied dependency contracts, as in the parent policy fixture. */
export function repeatedSourceExpiryFixture({ revision = '4' } = {}) {
  const f = repeatedMeasuredPolicyFixture(undefined, { recoveryDeliverySeconds: 26 });
  const original = [...f.quality.events];
  const row = f.quality.events.find(
    (e) =>
      e.kind === 'evaluated' &&
      e.revision === revision &&
      e.source.end === (revision === '4' ? 231 : 166),
  );
  assert(row);
  const oldPolicy = Number(row.window.sequence),
    source = f.snapshot.sourceIntervals.find((s) => s.sequence === row.source.sequence);
  const previous = f.snapshot.sourceIntervals.find((s) => s.sequence === source.previousSequence);
  const end = row.source.end;
  row.kind = 'rejected';
  row.reason = 'time';
  row.at = end + 2.004;
  row.evaluationDiagnostic = {
    selectedAt: end + 1.984,
    dispatchedAt: end + 2.0005,
    caughtAt: end + 2.002,
    session: {
      kind: 'source',
      cadenceReceiptID: null,
      evaluatedAt: end + 2.001,
      sourceAgeSeconds: end + 2.001 - end,
      sampleAgeSeconds: 0,
      sourceKey: {
        workerEpoch: source.workerEpoch,
        workerAttempt: source.workerAttempt,
        readerID: source.publication.readerId,
        sequence: source.sequence,
      },
    },
  };
  for (const key of ['window', 'evaluatedAt', 'reasons', 'state', 'evidence', 'action'])
    delete row[key];
  for (const event of f.quality.events) {
    if (event.window && Number(event.window.sequence) > oldPolicy)
      event.window.sequence = String(Number(event.window.sequence) - 1);
    for (const signal of [event.decoderStall, event.deliveryFailure])
      if (signal && Number(signal.sequence) > oldPolicy)
        signal.sequence = String(Number(signal.sequence) - 1);
    if (event.application && Number(event.application.windowSequence) > oldPolicy)
      event.application.windowSequence = String(Number(event.application.windowSequence) - 1);
  }
  for (const app of f.lifecycleQualification.applications)
    if (Number(app.application.windowSequence) > oldPolicy)
      app.application.windowSequence = String(Number(app.application.windowSequence) - 1);
  const next = f.quality.events.find(
    (e) => e.kind === 'evaluated' && e.source?.previousSequence === source.sequence,
  );
  next.reasons.push('telemetryGap');
  // The first accepted current-source report arrives at end+1.5. Repeated reports
  // retain this original helper; their later age fields cannot refresh it.
  const first = f.cadenceReports.rows.find((r) => r.evaluatedUptime === end + 1.5);
  assert(first);
  const lastCached = f.cadenceReports.rows.find((r) => r.evaluatedUptime === end + 1.75);
  const nearSelection = structuredClone(lastCached);
  nearSelection.evaluatedUptime = end + 1.97;
  nearSelection.receivedUptime = end + 1.96;
  nearSelection.response.status.observation.decoderCadence.progress.ageMs += 220;
  f.cadenceReports.rows.push(nearSelection);
  f.cadenceReports.rows.sort((a, b) => a.evaluatedUptime - b.evaluatedUptime);
  for (const [index, report] of f.cadenceReports.rows.entries()) {
    report.cadenceReceiptID ??= `f0000000-0000-4000-8000-${String(index + 1).padStart(12, '0')}`;
    if (report.evaluatedUptime < end || report.evaluatedUptime > end + 2.5) continue;
    const current = report.evaluatedUptime >= first.evaluatedUptime ? source : previous;
    const ageMs = Math.max(
      0,
      Math.round((report.receivedUptime - first.receivedUptime) * 1000) + 100,
    );
    const status = report.response.status;
    status.decodedVideoAgeUpperBoundMs = ageMs;
    Object.assign(status.observation.decodedVideo, {
      ended: false,
      invalidReason: null,
      completed: {
        sequence: Number(current.sequence),
        durationMs: 5000,
        ageMs,
        firstPTS: Number(current.firstDecodedPTS),
        lastPTS: Number(current.lastDecodedPTS),
        freshFrames: current.decodedFrames,
        duplicateFrames: 0,
        reorderedFrames: 0,
        valid: true,
      },
    });
    status.observation.processing = { scopeID: current.processing.scopeID };
    const R = report.receivedUptime,
      Q = R - report.requestSeconds,
      A = report.evaluatedUptime;
    report.timing = {
      controlStartedUptime: Q - 0.001,
      statusRequestStartedUptime: Q,
      responseReceivedUptime: R,
      probeReadStartedUptime: R + 0.001,
      probeReadFinishedUptime: R + 0.002,
      auditEvaluatedUptime: A,
    };
    for (const [key, a, b] of [
      ['maintenanceSeconds', 'controlStartedUptime', 'statusRequestStartedUptime'],
      ['statusHTTPSeconds', 'statusRequestStartedUptime', 'responseReceivedUptime'],
      ['responseProcessingSeconds', 'responseReceivedUptime', 'probeReadStartedUptime'],
      ['nativeProbeSeconds', 'probeReadStartedUptime', 'probeReadFinishedUptime'],
      ['postProbeProcessingSeconds', 'probeReadFinishedUptime', 'auditEvaluatedUptime'],
    ])
      report.timing[key] = report.timing[b] - report.timing[a];
  }
  row.evaluationDiagnostic.session.sampleAgeSeconds =
    0.1 +
    first.requestSeconds +
    row.evaluationDiagnostic.session.evaluatedAt -
    first.receivedUptime +
    0.0001;
  f.quality.events.sort((a, b) => a.at - b.at);
  for (const campaign of f.faults.campaigns) {
    campaign.confirmedEventIndex = f.quality.events.indexOf(original[campaign.confirmedEventIndex]);
    if (campaign.readyEventIndex !== undefined)
      campaign.readyEventIndex = f.quality.events.indexOf(original[campaign.readyEventIndex]);
  }
  return f;
}
