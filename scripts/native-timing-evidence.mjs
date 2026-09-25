import assert from 'node:assert/strict';
import { qualifyTimingContract } from './native-timing-contract.mjs';

/** Envelope consistency only. This does not qualify media, replay policy, or
 * permit an upgrade. The caller supplies the validated host profile. */
export function qualifyOwnedTimingEnvelopes(input, { timingProfile = 'strict1500-v1' } = {}) {
  const contract = qualifyTimingContract(input.provenance, timingProfile);
  for (const key of ['quality', 'checkpoint', 'cadence', 'delivery', 'ownedLifecycle'])
    qualifyTimingContract(input[key], timingProfile);
  qualifyTimingContract(input.checkpoint.quality, timingProfile);
  assert.equal(input.provenance.deliveryLatencyBudget, contract.decoderBudgetMs / 1000);
  assert.equal(input.delivery.latencyBudget, contract.decoderBudgetMs / 1000);
  assert.equal(input.delivery.maximumSampleAge, contract.maximumCadenceDeliveryReportAgeMs / 1000);
  return {
    formatVersion: 1,
    diagnosticOnly: true,
    timingMetadataConsistent: true,
    recoveryQualified: false,
    mediaQualified: false,
    automaticAdaptationQualified: false,
  };
}
