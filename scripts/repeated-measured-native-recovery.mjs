import assert from 'node:assert/strict';
import {
  qualifyMeasuredNativeMedia,
  measuredTrialArtifacts,
  qualifyMeasuredDeliveryOwnership,
  qualifyMeasuredDeliveryCoverage,
} from './measured-native-trial.mjs';
import { qualifyNativeProfileTransitions } from './native-profile-transitions.mjs';
import { qualifyMeasuredNativeLifecycle } from './measured-native-lifecycle.mjs';
import { qualifyRepeatedNativeAdmissions } from './repeated-native-admission.mjs';
import { qualifyRepeatedMeasuredPolicy } from './repeated-measured-policy.mjs';
import { qualifyRepeatedNativeReadiness } from './repeated-native-readiness.mjs';

export const repeatedMeasuredArtifacts = {
  ...measuredTrialArtifacts,
  candidateProof: ['native-candidate-measurement.json', 512 * 1024],
};

/** Complete repeated laboratory policy/media replay from raw exports. The native
 * harness must additionally decode full A/V and verify durable recording,
 * scoring, ingress and direct recording before declaring a complete run pass.
 * No summaries supplied by the caller replace these independent raw replays. */
export function qualifyRepeatedMeasuredNativeRecovery(input) {
  assert(
    input.nativeProbe?.formatVersion === 3 && input.nativeProbe.mode === 'repeated',
    'Repeated recovery requires raw repeated native probe',
  );
  assert.equal(
    input.candidateProof?.formatVersion,
    4,
    'Repeated recovery requires two raw candidates',
  );
  assert.equal(
    input.format?.formatVersion,
    9,
    'Repeated recovery requires five native media phases',
  );
  assert(
    input.faults?.formatVersion === 2 && input.faults.mode === 'repeated',
    'Repeated recovery requires two original owned faults',
  );
  const media = qualifyMeasuredNativeMedia(input, { cadenceAuditMode: 'repeated' });
  const profile = qualifyNativeProfileTransitions(input.format, input.snapshot, input.liveIDs, {
    sequence: 'repeated240',
    requireFrameEvidence: true,
  });
  const nativeLifecycle = qualifyMeasuredNativeLifecycle({
    lifecycle: input.lifecycle,
    quality: input.quality,
    format: input.format,
    snapshot: input.snapshot,
    startupFormat: input.startupFormat,
    liveIDs: input.liveIDs,
    sequence: 'repeated240',
  });
  const admissions = qualifyRepeatedNativeAdmissions({
    ...input,
    intervals: input.receiverIntervals,
    records: input.receiverRecords,
  });
  const ownership = qualifyMeasuredDeliveryOwnership(input, { ...media, profile, nativeLifecycle });
  const policy = qualifyRepeatedMeasuredPolicy({
    quality: input.quality,
    snapshot: input.snapshot,
    cadenceReports: input.cadenceReports,
    sourceIntervalQualification: media.source,
    profileQualification: profile,
    lifecycleQualification: nativeLifecycle,
    candidateWitnessQualifications: admissions.campaigns,
    deliveryAudit: input.deliveryAudit,
    faults: input.faults,
    format: input.format,
    archiveIDs: input.archiveIDs,
    liveIDs: input.liveIDs,
  });
  const readiness = qualifyRepeatedNativeReadiness({
    nativeProbe: input.nativeProbe,
    quality: input.quality,
    policyQualification: policy,
    scope: media.scope,
    publishingGeneration: input.format.publishingGeneration,
  });
  assert.equal(policy.confirmations.length, 2);
  assert.equal(policy.recoveries.length, 2);
  const coverage = policy.confirmations.map((confirmation, index) => ({
    campaign: String(index + 1),
    probation: qualifyMeasuredDeliveryCoverage(input.deliveryAudit, {
      revision: String(index * 2 + 1),
      start: confirmation.probation.start,
      end: confirmation.probation.end,
    }),
    recovery: qualifyMeasuredDeliveryCoverage(input.deliveryAudit, {
      revision: String(index * 2 + 2),
      start: policy.recoveries[index].sharedCoverage.start,
      end: policy.recoveries[index].sharedCoverage.end,
    }),
  }));
  return {
    ...media,
    profile,
    nativeLifecycle,
    admissions,
    ownership,
    policy,
    readiness,
    coverage,
    measuredRepeatedRecoveryQualified: true,
    repeatedRampUpQualified: true,
    productionUpgradeAuthorized: false,
    networkLossRecoveryQualified: false,
  };
}
