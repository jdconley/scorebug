import assert from 'node:assert/strict';
import { nativeCandidateHeadroom } from './native-candidate-headroom.mjs';

/** An isolated simulator route, never a production upgrade switch. */
export function nativeMeasuredTrial({
  environment,
  streaming,
  requirePublication,
  requireProcessing,
  holdSeconds,
  liveProfile,
}) {
  const flag = environment.SCOREBUG_TEST_MEASURED_TRIAL;
  const repeated =
    environment.SCOREBUG_TEST_BANDWIDTH_PROBE === 'repeated' ||
    environment.SCOREBUG_TEST_MEASURED_RECOVERY === 'repeated';
  if (repeated)
    assert.ok(
      flag === '1' &&
        environment.SCOREBUG_TEST_BANDWIDTH_PROBE === 'repeated' &&
        environment.SCOREBUG_TEST_MEASURED_RECOVERY === 'repeated' &&
        holdSeconds === 180,
      'Repeated measured trial requires paired repeated recovery/probe opt-ins and exactly 180 seconds',
    );
  if (flag === undefined) return false;
  assert.ok(
    flag === '1' &&
      streaming &&
      requirePublication &&
      requireProcessing &&
      Number.isSafeInteger(holdSeconds) &&
      holdSeconds >= 90 &&
      holdSeconds <= 600 &&
      liveProfile === '240p30' &&
      environment.SCOREBUG_TEST_DELIVERY_DEADLINE_MS === '1500' &&
      environment.SCOREBUG_TEST_CANDIDATE_PROFILE === '360p30' &&
      nativeCandidateHeadroom(environment) &&
      [
        'SCOREBUG_TEST_NATIVE_QUALITY',
        'SCOREBUG_TEST_NATIVE_CONFIRMATION',
        'SCOREBUG_TEST_ADAPTIVE_PROFILES',
        'SCOREBUG_TEST_PROFILE_TRANSITIONS',
        'SCOREBUG_TEST_SOURCE_CADENCE_PACING',
        'SCOREBUG_TEST_UPLINK_PROXY_PORT',
        'SCOREBUG_TEST_UPLINK_PROFILE',
        'SCOREBUG_TEST_DECODER_STALL',
        'SCOREBUG_TEST_CADENCE_REPORTS',
        'SCOREBUG_TEST_DEADLINE_RESETS',
      ].every((key) => environment[key] === undefined),
    'Measured trial requires exclusive candidate360, minimum-live, staged or repeated probe full-pipeline qualification',
  );
  return true;
}
