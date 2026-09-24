import assert from 'node:assert/strict';

export const candidateHeadroomStageRates = [500_000, 2_000_000, 12_000_000];

/** Explicit local qualification route; this does not enable production upgrades. */
export function nativeCandidateHeadroom(environment) {
  const flag = environment.SCOREBUG_TEST_CANDIDATE_HEADROOM;
  if (flag === undefined) return false;
  const repeated = environment.SCOREBUG_TEST_BANDWIDTH_PROBE === 'repeated';
  assert.ok(
    flag === '1' &&
      ['360p30', '540p30', '1080p30'].includes(environment.SCOREBUG_TEST_CANDIDATE_PROFILE) &&
      (repeated
        ? environment.SCOREBUG_TEST_MEASURED_RECOVERY === 'repeated' &&
          environment.SCOREBUG_TEST_MEASURED_TRIAL === '1' &&
          environment.SCOREBUG_TEST_CANDIDATE_PROFILE === '360p30'
        : environment.SCOREBUG_TEST_BANDWIDTH_PROBE === 'staged' &&
          environment.SCOREBUG_TEST_MEASURED_RECOVERY !== 'repeated') &&
      environment.SCOREBUG_TEST_LIVE_PROFILE === '240p30' &&
      environment.SCOREBUG_TEST_MOTION_FIXTURE === 'blocks16' &&
      environment.SCOREBUG_TEST_DIRECT_RTMP_RECORDER === '1',
    'Combined headroom requires explicit minimum-live, staged-probe, candidate and full-pipeline opt-ins',
  );
  return true;
}
