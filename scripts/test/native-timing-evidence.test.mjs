import assert from 'node:assert/strict';
import test from 'node:test';
import { timingContracts } from '../native-timing-contract.mjs';
const module = await import('../native-timing-evidence.mjs').catch((error) => {
  if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
  return {};
});
function fixture(profile) {
  const header = () => ({ timingContract: structuredClone(timingContracts[profile]) });
  return {
    provenance: {
      ...header(),
      deliveryLatencyBudget: timingContracts[profile].decoderBudgetMs / 1000,
    },
    quality: header(),
    checkpoint: { ...header(), quality: header() },
    cadence: header(),
    delivery: {
      ...header(),
      latencyBudget: timingContracts[profile].decoderBudgetMs / 1000,
      maximumSampleAge: 0.25,
    },
    ownedLifecycle: header(),
  };
}
test('owned diagnostic envelopes match trusted selection and grant no qualification', () => {
  assert.equal(typeof module.qualifyOwnedTimingEnvelopes, 'function');
  for (const profile of ['broadcast-reliability2000-v1', 'broadcast-reliability3000-v1']) {
    const input = fixture(profile),
      before = structuredClone(input);
    const result = module.qualifyOwnedTimingEnvelopes(input, { timingProfile: profile });
    assert.equal(result.timingMetadataConsistent, true);
    assert.equal(result.recoveryQualified, false);
    assert.equal(result.mediaQualified, false);
    assert.deepEqual(input, before);
    for (const key of Object.keys(input)) {
      const missing = structuredClone(input);
      delete missing[key];
      assert.throws(
        () => module.qualifyOwnedTimingEnvelopes(missing, { timingProfile: profile }),
        key,
      );
      const mixed = structuredClone(input);
      delete mixed[key].timingContract;
      assert.throws(
        () => module.qualifyOwnedTimingEnvelopes(mixed, { timingProfile: profile }),
        key,
      );
    }
    const nested = structuredClone(input);
    delete nested.checkpoint.quality.timingContract;
    assert.throws(() => module.qualifyOwnedTimingEnvelopes(nested, { timingProfile: profile }));
    const legacy = structuredClone(input);
    legacy.delivery.latencyBudget = 1.5;
    assert.throws(() => module.qualifyOwnedTimingEnvelopes(legacy, { timingProfile: profile }));
    assert.throws(() => module.qualifyOwnedTimingEnvelopes(input));
  }
});
