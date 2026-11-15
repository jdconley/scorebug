import assert from 'node:assert/strict';
import test from 'node:test';
import { nativeCandidateProfile } from '../native-candidate-measurement.mjs';
import { nativeBandwidthProbe } from '../native-bandwidth-probe.mjs';
import { nativeRelayImageTag } from '../native-relay-image.mjs';

const options = () => ({
  environment: {
    SCOREBUG_TEST_CANDIDATE_HEADROOM: '1',
    SCOREBUG_TEST_CANDIDATE_PROFILE: '1080p30',
    SCOREBUG_TEST_BANDWIDTH_PROBE: 'staged',
    SCOREBUG_TEST_LIVE_PROFILE: '240p30',
    SCOREBUG_TEST_MOTION_FIXTURE: 'blocks16',
    SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
  },
  streaming: true,
  requireProcessing: true,
  requirePublication: true,
  holdSeconds: 90,
  liveProfile: '240p30',
});
test('explicit combined qualification accepts all higher candidates from minimum live', () => {
  for (const profile of ['360p30', '540p30', '1080p30']) {
    const o = options();
    o.environment.SCOREBUG_TEST_CANDIDATE_PROFILE = profile;
    assert.equal(nativeCandidateProfile(o), profile);
    assert.equal(nativeBandwidthProbe(o), 'staged');
  }
});
test('combined qualification cannot silently omit or reinterpret required flags', () => {
  for (const [key, values] of Object.entries({
    SCOREBUG_TEST_CANDIDATE_HEADROOM: [undefined, '', 'true', '0'],
    SCOREBUG_TEST_CANDIDATE_PROFILE: [undefined, '', '240p30', 'bogus'],
    SCOREBUG_TEST_BANDWIDTH_PROBE: [undefined, '', 'renew', 'expire'],
    SCOREBUG_TEST_LIVE_PROFILE: [undefined, '540p30'],
    SCOREBUG_TEST_MOTION_FIXTURE: [undefined, 'noise'],
    SCOREBUG_TEST_DIRECT_RTMP_RECORDER: [undefined, '0'],
  }))
    for (const value of values) {
      const o = options();
      o.environment[key] = value;
      assert.throws(() => nativeCandidateProfile(o), key + '=' + value);
      assert.throws(() => nativeBandwidthProbe(o), key + '=' + value);
    }
});
test('HD probe qualification selects an isolated relay image and requires all parent modes', () => {
  const flags = {
    requirePublication: true,
    requireReceiverProbe: true,
    stagedReceiverProbe: true,
    candidateHeadroom: true,
  };
  assert.equal(nativeRelayImageTag(flags), 'scorebug/ingest:staged-probe-hd-v2');
  for (const key of ['requirePublication', 'requireReceiverProbe', 'stagedReceiverProbe'])
    assert.throws(() => nativeRelayImageTag({ ...flags, [key]: false }));
  for (const value of [null, 1, 'true'])
    assert.throws(() => nativeRelayImageTag({ ...flags, candidateHeadroom: value }));
});
