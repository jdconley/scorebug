import {
  qualifyMeasuredNativeEvidence,
  qualifyMeasuredDeliveryOwnership,
  qualifyMeasuredDeliveryCoverage,
} from './measured-native-trial.mjs';
import { qualifyMeasuredTrialConfirmedPrefix } from './measured-trial-policy.mjs';
import { qualifyMeasuredRecoveryFault } from './measured-recovery-fault.mjs';
import { qualifyMeasuredRecoveryPolicy } from './measured-recovery-policy.mjs';

/** Complete bounded laboratory recovery proof from raw exports. The native
 * harness additionally requires full A/V decoding, durable archive, scoring,
 * ingress and direct-recorder checks before reporting a complete run pass.
 */
export function qualifyMeasuredNativeRecovery(input) {
  const evidence = qualifyMeasuredNativeEvidence(input, { recovery: true });
  const dependencies = {
    quality: input.quality,
    snapshot: input.snapshot,
    cadenceReports: input.cadenceReports,
    sourceIntervalQualification: evidence.source,
    profileQualification: evidence.profile,
    lifecycleQualification: evidence.nativeLifecycle,
    candidateWitnessQualification: evidence.witness,
  };
  const prefix = qualifyMeasuredTrialConfirmedPrefix(dependencies);
  const ownership = qualifyMeasuredDeliveryOwnership(input, evidence);
  const prefixDelivery = qualifyMeasuredDeliveryCoverage(input.deliveryAudit, {
    revision: '1',
    start: prefix.probation.start,
    end: prefix.probation.end,
  });
  const fault = qualifyMeasuredRecoveryFault({
    ...dependencies,
    fault: input.fault,
    format: input.format,
    scope: evidence.scope,
    prefix,
    archiveIDs: input.archiveIDs,
    liveIDs: input.liveIDs,
    deliveryAudit: input.deliveryAudit,
  });
  const recovery = qualifyMeasuredRecoveryPolicy({
    ...dependencies,
    prefix,
    faultQualification: fault,
    deliveryAudit: input.deliveryAudit,
  });
  const recoveryDelivery = qualifyMeasuredDeliveryCoverage(input.deliveryAudit, {
    revision: '2',
    start: recovery.sharedCoverage.start,
    end: recovery.sharedCoverage.end,
  });
  return {
    ...evidence,
    prefix,
    ownership,
    prefixDelivery,
    fault,
    recovery,
    recoveryDelivery,
    measuredRecoveryQualified: true,
    productionUpgradeAuthorized: false,
    repeatedRampUpQualified: false,
    networkLossRecoveryQualified: false,
  };
}
