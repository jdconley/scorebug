import assert from 'node:assert/strict';
import { repeatedMeasuredPolicyFixture } from './repeated-measured-policy-evidence.mjs';

/** Synthetic component extension only. Preserve original source/policy ordinals;
 * inserted rejection events change only references to their actual array indices. */
export function repeatedRecoveryInvalidationFixture(
  base = repeatedMeasuredPolicyFixture(undefined, { recoveryDeliverySeconds: 22 }),
  { revisions = ['2'], reportTimes = {} } = {},
) {
  const f = base;
  const original = [...f.quality.events];
  for (const [index, row] of f.cadenceReports.rows.entries())
    row.cadenceReceiptID ??= `f0000000-0000-4000-8000-${String(index + 1).padStart(12, '0')}`;
  for (const revision of revisions) {
    assert(['2', '4'].includes(revision));
    const at = reportTimes[revision] ?? (revision === '2' ? 167.25 : 227.25);
    const row = f.cadenceReports.rows.find((r) => r.evaluatedUptime === at);
    assert(row);
    const received = at - 0.01,
      request = received - 0.12;
    Object.assign(row, {
      receivedUptime: received,
      requestSeconds: 0.12,
      residenceSeconds: 0.01,
      sampleAgeSeconds: 0.27,
      observedStall: null,
    });
    row.response.status.decoderCadenceAgeUpperBoundMs = 140;
    row.timing = {
      controlStartedUptime: request - 0.02,
      statusRequestStartedUptime: request,
      responseReceivedUptime: received,
      probeReadStartedUptime: received + 0.001,
      probeReadFinishedUptime: received + 0.002,
      auditEvaluatedUptime: at,
      maintenanceSeconds: 0.02,
      statusHTTPSeconds: 0.12,
      responseProcessingSeconds: 0.001,
      nativeProbeSeconds: 0.001,
      postProbeProcessingSeconds: 0.008,
    };
    // Native stage durations are differences of these exact uptime samples.
    for (const [key, start, end] of [
      ['maintenanceSeconds', 'controlStartedUptime', 'statusRequestStartedUptime'],
      ['statusHTTPSeconds', 'statusRequestStartedUptime', 'responseReceivedUptime'],
      ['responseProcessingSeconds', 'responseReceivedUptime', 'probeReadStartedUptime'],
      ['nativeProbeSeconds', 'probeReadStartedUptime', 'probeReadFinishedUptime'],
      ['postProbeProcessingSeconds', 'probeReadFinishedUptime', 'auditEvaluatedUptime'],
    ])
      row.timing[key] = row.timing[end] - row.timing[start];
    const reset = f.quality.events.find((e) => e.kind === 'applied' && e.revision === revision);
    const event = { kind: 'rejected', reason: 'cadence-freshness', at: at + 0.04, closed: false };
    for (const key of [
      'revision',
      'profileID',
      'receipt',
      'application',
      'profileReceipt',
      'acknowledgedAt',
    ])
      event[key] = structuredClone(reset[key]);
    event.evaluationDiagnostic = {
      selectedAt: at + 0.01,
      dispatchedAt: at + 0.015,
      caughtAt: at + 0.03,
      session: {
        kind: 'cadence',
        cadenceReceiptID: row.cadenceReceiptID,
        evaluatedAt: at + 0.02,
        sampleAgeSeconds: 0.291,
        sourceAgeSeconds: null,
        sourceKey: null,
      },
    };
    f.quality.events.push(event);
  }
  f.quality.events.sort((a, b) => a.at - b.at);
  for (const campaign of f.faults.campaigns) {
    campaign.confirmedEventIndex = f.quality.events.indexOf(original[campaign.confirmedEventIndex]);
    if (campaign.readyEventIndex !== undefined)
      campaign.readyEventIndex = f.quality.events.indexOf(original[campaign.readyEventIndex]);
  }
  return f;
}
