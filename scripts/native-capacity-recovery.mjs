import assert from 'node:assert/strict';
import { isAbsolute } from 'node:path';

/** Complete host selection only; no resources or native recovery qualification. */
export function nativeCapacityRecovery({ environment, streaming, holdSeconds }) {
  if (
    environment.SCOREBUG_TEST_CAPACITY_RECOVERY === undefined &&
    environment.SCOREBUG_TEST_UPLINK_PROFILE !== 'capacity550k'
  )
    return false;
  assert.equal(streaming, true, 'Capacity recovery requires streaming');
  assert.equal(holdSeconds, 180, 'Capacity recovery requires exactly180seconds');
  assert(
    typeof environment.SCOREBUG_TEST_FILE_INPUT === 'string' &&
      isAbsolute(environment.SCOREBUG_TEST_FILE_INPUT),
    'Capacity recovery requires absolute file input',
  );
  const required = {
    SCOREBUG_TEST_CAPACITY_RECOVERY: '1',
    SCOREBUG_TEST_UPLINK_PROFILE: 'capacity550k',
    SCOREBUG_TEST_PROBE_POLICY: 'recovery-budget-v1',
    SCOREBUG_TEST_STREAM_HOLD_SECONDS: '180',
    SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
    SCOREBUG_TEST_RELAY_PUBLICATION: '1',
    SCOREBUG_TEST_WORKER_PROCESSING: '1',
    SCOREBUG_TEST_MEASURED_TRIAL: '1',
    SCOREBUG_TEST_CANDIDATE_HEADROOM: '1',
    SCOREBUG_TEST_CANDIDATE_PROFILE: '360p30',
    SCOREBUG_TEST_LIVE_PROFILE: '240p30',
    SCOREBUG_TEST_BANDWIDTH_PROBE: 'staged',
    SCOREBUG_TEST_DELIVERY_DEADLINE_MS: '1500',
    SCOREBUG_TEST_PUBLISH_PEER_LATENCY_MS: '400',
  };
  for (const [key, value] of Object.entries(required))
    assert.equal(environment[key], value, `Capacity recovery requires ${key}=${value}`);
  for (const key of [
    'SCOREBUG_TEST_FILE_CAPTURE',
    'SCOREBUG_TEST_UPLINK_PROXY_PORT',
    'SCOREBUG_TEST_MEASURED_RECOVERY',
    'SCOREBUG_TEST_MOTION_FIXTURE',
    'SCOREBUG_FIXTURE_FAIL_AFTER',
    'SCOREBUG_TEST_NATIVE_QUALITY',
    'SCOREBUG_TEST_NATIVE_CONFIRMATION',
    'SCOREBUG_TEST_PROFILE_TRANSITIONS',
    'SCOREBUG_TEST_ADAPTIVE_PROFILES',
    'SCOREBUG_TEST_SOURCE_CADENCE_PACING',
    'SCOREBUG_TEST_DECODER_STALL',
    'SCOREBUG_TEST_CADENCE_REPORTS',
    'SCOREBUG_TEST_DEADLINE_RESETS',
    'SCOREBUG_TEST_PUBLISH_PACING',
    'SCOREBUG_TEST_DELIVERY_PROFILE',
  ])
    assert.equal(environment[key], undefined, `Capacity recovery conflicts with ${key}`);
  assert(
    environment.SCOREBUG_TEST_DECODER_THREADING === undefined ||
      environment.SCOREBUG_TEST_DECODER_THREADING === 'slice',
    'Capacity recovery supports slice decoding only',
  );
  return true;
}
