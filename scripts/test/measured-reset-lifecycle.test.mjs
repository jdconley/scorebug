import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { qualifyMeasuredNativeLifecycle } from '../measured-native-lifecycle.mjs';
import { qualifyNativeProfileTransitions } from '../native-profile-transitions.mjs';
const input = () =>
  JSON.parse(
    gunzipSync(
      fs.readFileSync(
        new URL('./fixtures/measured-reset-lifecycle-wX2pa6.json.gz', import.meta.url),
      ),
    ),
  ).input;
const qualify = (f) =>
  qualifyMeasuredNativeLifecycle({
    ...f,
    profileQualification: qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, {
      sequence: 'measured240',
      requireFrameEvidence: true,
    }),
  });
test('historical trial measurement on later reset is not current reset authority', () => {
  const f = input(),
    r = qualify(f);
  assert.equal(r.applications.length, 2);
  assert.equal(r.applications[1].candidateID, null);
  assert.equal(r.applications[1].target, '240p30');
  assert.equal(r.upgradeAuthorized, false);
});
test('foreign historical candidate on reset rejects', () => {
  const f = input();
  f.lifecycle.profileRequests[1].candidateMeasurementID = f.lifecycle.profileRequests[1].requestID;
  assert.throws(() => qualify(f));
});
test('candidate-bearing reset action rejects', () => {
  const f = input();
  const e = f.quality.events.filter((e) => e.kind === 'applied')[1];
  e.action.candidateID = e.application.candidateID =
    f.lifecycle.profileRequests[0].candidateMeasurementID;
  assert.throws(() => qualify(f));
});
