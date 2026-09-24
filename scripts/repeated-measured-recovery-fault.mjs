import { qualifyCadenceAuditEnvelope } from './cadence-audit-envelope.mjs';
import assert from 'node:assert/strict';
import { qualifyRepeatedMeasuredRecoveryFaultCampaign } from './measured-recovery-fault.mjs';

const time = (value) => typeof value === 'number' && Number.isFinite(value) && value >= 0;
const id = (value) => {
  assert(
    typeof value === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(value),
    'Invalid repeated fault identity',
  );
  return value.toLowerCase();
};
/** Fault causality only. Confirmation, source and media qualifications are
 * independently reconstructed dependency contracts; their health duration is
 * never inferred here. Every join retains the complete original raw timeline. */
export function qualifyRepeatedMeasuredRecoveryFaults(input) {
  const { faults, quality, cadenceReports, scope, confirmations, profileQualification } = input;
  assert(
    faults?.formatVersion === 2 &&
      faults.mode === 'repeated' &&
      faults.closed === true &&
      faults.failed === false,
    'Invalid repeated fault envelope',
  );
  assert(!Object.hasOwn(faults, 'events'), 'Unowned top-level fault events');
  assert.deepEqual(faults.scope, scope);
  assert(
    Array.isArray(faults.campaigns) && faults.campaigns.length === 2,
    'Exactly two owned pauses required',
  );
  assert(
    Array.isArray(confirmations) && confirmations.length === 2,
    'Exactly two independent confirmations required',
  );
  assert(
    quality?.formatVersion === 4 &&
      quality.overflow === false &&
      quality.measuredSourceEvaluationEnabled === true &&
      quality.decoderStallEnabled === true,
  );
  const events = quality.events;
  assert(Array.isArray(events) && events.length > 0 && events.length <= 512);
  assert(events[0].kind === 'bootstrap' && events[0].revision === '0');
  assert(events.at(-1).kind === 'stopped' && events.at(-1).closed === true);
  let at = -1;
  for (const event of events) {
    assert(time(event.at) && event.at >= at, 'Global repeated fault timeline regressed');
    at = event.at;
    assert(
      [
        'bootstrap',
        'evaluated',
        'candidate',
        'applied',
        'transition',
        'decoderStall',
        'deliveryFailure',
        'stopped',
      ].includes(event.kind),
      'Unsupported repeated fault timeline event',
    );
  }
  assert.equal(events.filter((e) => e.kind === 'bootstrap').length, 1);
  assert.equal(events.filter((e) => e.kind === 'stopped').length, 1);
  qualifyCadenceAuditEnvelope(cadenceReports, { cadenceAuditMode: 'repeated' });
  let reportAt = -1;
  for (const row of cadenceReports.rows) {
    assert(
      time(row.evaluatedUptime) && row.evaluatedUptime > reportAt,
      'Global cadence timeline regressed',
    );
    reportAt = row.evaluatedUptime;
  }
  assert.deepEqual(profileQualification?.scope, scope);
  assert.equal(profileQualification.phases?.length, 5);
  assert.equal(profileQualification.receipts?.length, 4);
  const applications = events.filter((e) => e.kind === 'applied');
  assert.equal(applications.length, 4);
  applications.forEach((e, i) => {
    assert.equal(e.revision, String(i + 1));
    assert.equal(e.action?.fromRevision, String(i));
    assert.equal(e.application?.fromRevision, String(i));
    assert.equal(e.action.kind, i % 2 ? 'reset' : 'trial');
    assert.deepEqual(
      e.profileReceipt,
      profileQualification.receipts[i],
      'Original native profile receipt mismatch',
    );
    assert.equal(
      id(e.receipt.encoderSessionID),
      id(profileQualification.phases[i + 1].encoderSessionID),
    );
  });
  const candidates = events.filter((e) => e.kind === 'candidate');
  assert.equal(candidates.length, 2);
  const triggers = events
    .map((event, index) => ({ event, index }))
    .filter(({ event }) => ['decoderStall', 'deliveryFailure'].includes(event.kind));
  assert.equal(triggers.length, 2, 'Exactly two supported fault triggers required');
  const candidateIDs = new Set();
  let previous;
  const campaigns = faults.campaigns.map((fault, index) => {
    const campaign = String(index + 1),
      trialRevision = String(index * 2 + 1),
      resetRevision = String(index * 2 + 2);
    const confirmation = confirmations[index],
      trial = applications[index * 2],
      reset = applications[index * 2 + 1];
    const trigger = triggers[index],
      resetIndex = events.indexOf(reset);
    assert.equal(fault.campaign, campaign);
    assert.equal(fault.trialRevision, trialRevision);
    assert.equal(confirmation.campaign, campaign);
    assert.equal(confirmation.appliedRevision, String(index * 2));
    assert.equal(confirmation.trialRevision, trialRevision);
    assert.equal(confirmation.rawEventCount, events.length);
    assert.equal(confirmation.nextEventIndex, confirmation.confirmedEventIndex + 1);
    assert(
      Number.isSafeInteger(confirmation.confirmedEventIndex) &&
        confirmation.confirmedEventIndex > events.indexOf(candidates[index]) &&
        confirmation.confirmedEventIndex < trigger.index,
    );
    assert.equal(fault.confirmedEventIndex, confirmation.confirmedEventIndex);
    const candidate = candidates[index],
      confirmed = events[confirmation.confirmedEventIndex];
    assert(
      events.indexOf(trial) < events.indexOf(candidate),
      'Candidate must follow its original trial',
    );
    for (const event of [candidate, confirmed]) {
      for (const field of [
        'application',
        'receipt',
        'profileReceipt',
        'acknowledgedAt',
        'revision',
        'profileID',
      ]) {
        assert.deepEqual(event[field], trial[field], `Event changed its original trial ${field}`);
      }
    }
    assert.deepEqual(candidate.action, trial.action, 'Candidate changed its original trial action');
    const candidateID = id(fault.candidateID);
    assert.equal(candidateID, id(trial.application.candidateID));
    assert.equal(candidateID, id(candidates[index].candidate?.id));
    assert.equal(
      id(events[confirmation.confirmedEventIndex].application?.candidateID),
      candidateID,
    );
    assert(!candidateIDs.has(candidateID), 'Reused fault candidate');
    candidateIDs.add(candidateID);
    assert.equal(trigger.event.revision, trialRevision);
    assert.equal(resetIndex, trigger.index + 1, 'Reset must immediately follow its own fault');
    const before = fault.beforePauseSample,
      paused = fault.pausedSample;
    assert(before?.value && paused?.value, 'Missing original pause observations');
    if (previous) {
      assert(fault.pauseSentAt >= previous.fault.resumeSentAt, 'Owned pauses overlap');
      assert.deepEqual(fault.identity, previous.fault.identity, 'Owned process identity changed');
      assert.deepEqual(
        before.value.context,
        previous.fault.beforePauseSample.value.context,
        'Owned worker/publication changed',
      );
      assert.equal(
        paused.value.decoderCadence?.scopeID,
        previous.fault.pausedSample.value.decoderCadence?.scopeID,
        'Owned decoder scope changed',
      );
      assert(
        paused.value.decoderCadence.progress.lastFreshPTS >
          previous.fault.pausedSample.value.decoderCadence.progress.lastFreshPTS,
        'Paused decoder PTS did not advance',
      );
      assert(
        before.value.decoderCadence.progress.lastFreshPTS >
          previous.fault.pausedSample.value.decoderCadence.progress.lastFreshPTS,
        'New pause inherits previous stalled progress',
      );
      assert(
        confirmation.confirmedEventIndex > previous.resetEventIndex,
        'Second confirmation precedes first reset',
      );
    }
    const result = qualifyRepeatedMeasuredRecoveryFaultCampaign(
      { ...input, fault, prefix: confirmation },
      {
        campaign,
        trialRevision,
        resetRevision,
        trialPhaseIndex: index * 2 + 1,
        triggerEventIndex: trigger.index,
        resetEventIndex: resetIndex,
      },
    );
    const resumedAt = cadenceReports.rows[result.resumedCadenceReportIndex].evaluatedUptime;
    const nextBoundary = index === 0 ? applications[2].application.admittedAt : events.at(-1).at;
    assert(resumedAt < nextBoundary, 'Fault resumed progress escaped its original campaign');
    previous = { fault, resetEventIndex: resetIndex };
    return {
      ...result,
      campaign,
      candidateID,
      appliedRevision: confirmation.appliedRevision,
      trialRevision,
      resetRevision,
      confirmedEventIndex: confirmation.confirmedEventIndex,
    };
  });
  return {
    scope: structuredClone(scope),
    campaigns,
    faultQualified: true,
    recoveryQualified: false,
    repeatedPolicyQualified: false,
    productionUpgradeAuthorized: false,
  };
}
