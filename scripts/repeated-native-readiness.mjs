import assert from 'node:assert/strict';
import { qualifyRepeatedNativeBandwidthProbe } from './repeated-native-bandwidth-probe.mjs';

const finite = (value) => typeof value === 'number' && Number.isFinite(value) && value >= 0;
const sameID = (left, right) => {
  assert.match(left, /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i);
  assert.match(right, /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i);
  assert.equal(left.toLowerCase(), right.toLowerCase());
};

/** Join raw probe readiness to independently replayed policy checkpoints.
 * The caller must obtain policyQualification from the complete global replay;
 * this component does not manufacture health from native readiness metadata.
 * A context read can precede asynchronous allocation, so a newer checkpoint at
 * begin is allowed while the captured checkpoint must remain fresh and owned. */
export function qualifyRepeatedNativeReadiness({
  nativeProbe,
  quality,
  policyQualification,
  scope,
  publishingGeneration,
}) {
  const probe = qualifyRepeatedNativeBandwidthProbe(nativeProbe, { scope, publishingGeneration });
  const policy = policyQualification;
  assert.deepEqual(policy?.scope, scope, 'Readiness policy scope mismatch');
  assert.equal(quality?.formatVersion, 4);
  assert.equal(quality.overflow, false);
  const events = quality.events;
  assert(Array.isArray(events) && events.length > 0 && events.length <= 512);
  assert.equal(policy.rawEventCount, events.length, 'Readiness requires full policy history');
  assert(Array.isArray(policy.healthHistory) && policy.healthHistory.length <= events.length);
  assert.equal(policy.recoveries?.length, 2, 'Readiness requires both replayed recoveries');
  // The full policy replay owns raw receipt/clock validation. Retain its exact
  // event joins here: asynchronous serialization must not hide an invalidation
  // that had already cleared native readiness before probe allocation.
  const invalidations = policy.invalidations ?? [];
  assert(Array.isArray(invalidations) && invalidations.length <= events.length);
  const invalidationByIndex = new Map();
  for (const invalidation of invalidations) {
    const {
      eventIndex,
      reportIndex,
      nextReportIndex,
      availableAt,
      revision,
      evaluatedAt,
      caughtAt,
      receiptID,
    } = invalidation;
    assert(Number.isSafeInteger(eventIndex) && eventIndex > 0 && eventIndex < events.length);
    assert(Number.isSafeInteger(reportIndex) && reportIndex >= 0);
    assert.equal(
      nextReportIndex,
      reportIndex + 1,
      'Readiness invalidation replacement index differs',
    );
    assert(finite(availableAt), 'Missing independently qualified fresh availability');
    assert(!invalidationByIndex.has(eventIndex), 'Duplicate readiness invalidation');
    const event = events[eventIndex],
      diagnostic = event.evaluationDiagnostic;
    assert(
      event.kind === 'rejected' && event.reason === 'cadence-freshness',
      'Readiness invalidation lacks original rejection',
    );
    assert(['2', '4'].includes(revision) && event.revision === revision);
    assert(
      finite(evaluatedAt) && finite(caughtAt) && evaluatedAt <= caughtAt && caughtAt <= event.at,
    );
    assert.equal(
      diagnostic?.session?.evaluatedAt,
      evaluatedAt,
      'Readiness invalidation time differs',
    );
    assert.equal(diagnostic?.caughtAt, caughtAt, 'Readiness invalidation catch differs');
    sameID(diagnostic?.session?.cadenceReceiptID, receiptID);
    invalidationByIndex.set(eventIndex, invalidation);
  }
  events.forEach((event, index) => {
    if (event.kind === 'rejected')
      assert(
        invalidationByIndex.has(index),
        'Missing independently qualified readiness invalidation',
      );
  });
  const seen = new Set();
  for (const checkpoint of policy.healthHistory) {
    assert(
      Number.isSafeInteger(checkpoint.eventIndex) &&
        checkpoint.eventIndex > 0 &&
        checkpoint.eventIndex < events.length,
    );
    const key = `${checkpoint.revision}:${checkpoint.healthSequence}`;
    assert(!seen.has(key), 'Duplicate readiness health checkpoint');
    seen.add(key);
  }
  const campaigns = probe.campaigns.map((campaign, index) => {
    const revision = String(index * 2),
      context = campaign.context,
      origin = campaign.campaignStartedAt;
    assert.equal(context.appliedRevision, revision);
    const baselines = events.filter(
      (event) => event.revision === revision && event.kind === (index ? 'applied' : 'bootstrap'),
    );
    assert.equal(baselines.length, 1, 'Missing original readiness baseline');
    const baseline = baselines[0],
      baselineIndex = events.indexOf(baseline);
    assert.equal(baseline.profileID, context.baselineProfile);
    assert.equal(baseline.receipt.bitRate, context.baselineBitRate);
    assert.equal(baseline.receipt.generation, publishingGeneration);
    sameID(baseline.receipt.encoderSessionID, context.encoderSessionID);
    sameID(baseline.receipt.configurationID, context.configurationID);
    assert.equal(baseline.acknowledgedAt, context.acknowledgedAt);
    assert(baseline.at <= origin, 'Readiness predates its baseline');
    const checkpoints = policy.healthHistory.filter(
      (h) => h.revision === revision && h.healthSequence === context.healthSequence,
    );
    assert.equal(checkpoints.length, 1, 'Readiness lacks independently replayed health');
    const checkpoint = checkpoints[0],
      row = events[checkpoint.eventIndex],
      window = row.window;
    assert.equal(row.kind, 'evaluated');
    assert.equal(row.revision, revision);
    assert.equal(window?.revision, revision);
    assert.equal(window.sequence, context.healthSequence);
    assert.equal(window.end, checkpoint.healthyThrough);
    assert.equal(context.healthySince, checkpoint.healthySince);
    assert.equal(context.healthyThrough, checkpoint.healthyThrough);
    assert(context.healthySince >= baseline.acknowledgedAt);
    assert(
      context.healthyThrough - context.healthySince >= (index ? 10 : 4),
      'Insufficient readiness health duration',
    );
    assert(checkpoint.eventIndex > baselineIndex);
    for (const field of ['receipt', 'profileReceipt', 'application', 'acknowledgedAt', 'profileID'])
      assert.deepEqual(row[field], baseline[field], `Readiness changed original baseline ${field}`);
    assert([row.at, row.evaluatedAt, window.observedAt, window.end].every(finite));
    // Native readiness is readable after evaluation; the independent diagnostic
    // task may serialize that decision after asynchronous probe allocation.
    assert(
      window.end <= window.observedAt &&
        window.observedAt <= row.evaluatedAt &&
        row.evaluatedAt <= row.at &&
        row.evaluatedAt <= origin,
      'Readiness health was unavailable at native begin',
    );
    assert(
      origin - window.end <= 2 && origin - window.observedAt <= 2,
      'Readiness health is stale',
    );
    assert(
      !events.some(
        (e, i) => i > baselineIndex && e.kind === 'applied' && e.application.admittedAt <= origin,
      ),
      'Readiness baseline was replaced before native begin',
    );
    // A newer healthy observation may advance while begin is asynchronous,
    // but an intervening reset of health invalidates the captured context. A
    // weak evaluated event has no strong checkpoint and cannot be ignored.
    for (let i = checkpoint.eventIndex + 1; i < events.length; i++) {
      const next = events[i],
        evaluatedAt = invalidationByIndex.get(i)?.evaluatedAt ?? next.evaluatedAt ?? next.at;
      if (evaluatedAt > origin) continue;
      assert.equal(next.kind, 'evaluated', 'Intervening event invalidates native readiness');
      const later = policy.healthHistory.find((h) => h.eventIndex === i);
      assert(later, 'Intervening evaluation lacks strong readiness health');
      assert(
        later.revision === revision &&
          later.healthySince === context.healthySince &&
          later.healthyThrough >= context.healthyThrough &&
          Number(later.healthSequence) >= Number(context.healthSequence),
        'Intervening health invalidates captured native readiness',
      );
    }
    let precedingRecoveryEnd;
    if (index) {
      const recovery = policy.recoveries[index - 1],
        shared = recovery.sharedCoverage;
      assert(shared && [shared.start, shared.end, shared.coverageSeconds].every(finite));
      assert.equal(shared.coverageSeconds, shared.end - shared.start);
      assert(shared.coverageSeconds >= 10, 'Insufficient preceding shared recovery');
      const invalidatedThrough = Math.max(
        0,
        ...invalidations
          .filter((value) => value.revision === revision && value.evaluatedAt <= origin)
          .map((value) => Math.max(value.caughtAt, value.availableAt)),
      );
      assert(
        shared.start >= invalidatedThrough,
        'Recovery predates fresh availability after invalidation',
      );
      assert(
        Array.isArray(shared.policyWindowSequences) && shared.policyWindowSequences.length > 0,
      );
      assert.equal(shared.windowCount, shared.policyWindowSequences.length);
      assert(Array.isArray(recovery.healthyWindows));
      let end = shared.start,
        last;
      for (const sequence of shared.policyWindowSequences) {
        const matches = recovery.healthyWindows.filter((w) => w.policySequence === sequence);
        assert.equal(matches.length, 1, 'Missing credited recovery window');
        const w = matches[0],
          event = events[w.eventIndex];
        assert(event?.kind === 'evaluated' && event.revision === revision);
        assert.equal(event.window.sequence, w.policySequence);
        assert.equal(event.window.start, w.start);
        assert.equal(event.window.end, w.end);
        assert.equal(event.evaluatedAt, w.evaluatedAt);
        assert.equal(w.start, end, 'Preceding shared recovery has a gap');
        assert(
          w.end > w.start && w.eventIndex > baselineIndex && w.eventIndex <= checkpoint.eventIndex,
        );
        assert(
          w.evaluatedAt <= row.evaluatedAt && w.evaluatedAt <= origin,
          'Recovery was not complete at readiness',
        );
        end = w.end;
        last = w;
      }
      assert.equal(end, shared.end);
      assert(
        finite(shared.qualifiedAt) &&
          shared.qualifiedAt >= last.evaluatedAt &&
          shared.qualifiedAt <= origin,
        'Shared recovery evidence was unavailable at native begin',
      );
      assert(shared.end <= context.healthyThrough && shared.start >= context.healthySince);
      assert(Number(last.policySequence) <= Number(context.healthSequence));
      precedingRecoveryEnd = shared.end;
    }
    return {
      campaign: campaign.campaign,
      appliedRevision: revision,
      healthSequence: context.healthSequence,
      healthEventIndex: checkpoint.eventIndex,
      healthySince: context.healthySince,
      healthyThrough: context.healthyThrough,
      campaignStartedAt: origin,
      ...(precedingRecoveryEnd === undefined ? {} : { precedingRecoveryEnd }),
    };
  });
  return { scope, campaigns, readinessQualified: true, productionUpgradeAuthorized: false };
}
