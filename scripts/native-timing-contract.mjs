import assert from 'node:assert/strict';

// Product/experimental budgets, not platform guidance. Capture evaluation includes
// report age plus 250ms scheduling allowance; repolling never renews media age.
const profile = (
  profileId,
  decoderBudgetMs,
  maximumCaptureWindowEvaluationAgeMs,
  reportAgeMs = 250,
) =>
  Object.freeze({
    formatVersion: 1,
    profileId,
    decoderBudgetMs,
    maximumCaptureWindowEvaluationAgeMs,
    maximumCompletedDecoderWindowReportAgeMs: 2000,
    maximumCadenceDeliveryReportAgeMs: reportAgeMs,
    decoderStallThresholdMs: 1000,
    scope: 'owned-capacity-diagnostic',
  });
export const timingContracts = Object.freeze({
  'strict1500-v1': profile('strict1500-v1', 1500, 2000),
  'broadcast-reliability2000-v1': profile('broadcast-reliability2000-v1', 2000, 2500),
  'broadcast-reliability3000-v1': profile('broadcast-reliability3000-v1', 3000, 3500),
  'broadcast-reliability3000-v3': profile('broadcast-reliability3000-v3', 3000, 4250, 1000),
  'broadcast-reliability6000-v1': profile('broadcast-reliability6000-v1', 6000, 6500),
});
export function timingContractForProfile(profileId = 'strict1500-v1') {
  assert(
    typeof profileId === 'string' && Object.hasOwn(timingContracts, profileId),
    'Unknown timing profile',
  );
  return timingContracts[profileId];
}
/** Leaf only. Complete host/native routes must also validate every route input. */
export function requestedTimingContract(environment) {
  const selected = environment.SCOREBUG_TEST_TIMING_PROFILE;
  const contract = timingContractForProfile(selected);
  if (selected !== undefined) {
    assert.equal(
      environment.SCOREBUG_TEST_OWNED_MEASUREMENT,
      '1',
      'Timing profile requires complete owned recovery',
    );
    assert.equal(
      environment.SCOREBUG_TEST_UPLINK_PROFILE,
      'capacity750k-retry',
      'Timing profile requires owned retry',
    );
    assert.equal(
      environment.SCOREBUG_TEST_CAPACITY_EVIDENCE,
      'token-budget-v1',
      'Timing profile requires token-budget evidence',
    );
    assert.equal(
      environment.SCOREBUG_TEST_DELIVERY_DEADLINE_MS,
      String(contract.decoderBudgetMs),
      'Timing profile deadline must agree exactly in milliseconds',
    );
  }
  return contract;
}
/** The caller supplies a trusted host selection, never a selector from evidence. */
export function qualifyTimingContract(envelope, profileId = 'strict1500-v1') {
  const expected = timingContractForProfile(profileId);
  assert(
    envelope && typeof envelope === 'object' && !Array.isArray(envelope),
    'Missing timing envelope',
  );
  if (profileId === 'strict1500-v1') {
    assert(!Object.hasOwn(envelope, 'timingContract'), 'Legacy evidence rejects timing metadata');
  } else {
    assert.deepEqual(
      envelope.timingContract,
      expected,
      'Missing, mixed or altered timing contract',
    );
  }
  return expected;
}
export function timingContractMetadata(contract) {
  assert.equal(
    timingContractForProfile(contract.profileId),
    contract,
    'Trusted immutable timing contract required',
  );
  return contract.profileId === 'strict1500-v1' ? {} : { timingContract: contract };
}
