import assert from 'node:assert/strict';
import test from 'node:test';
import { repeatedLifecycleFixture } from './fixtures/repeated-lifecycle-evidence.mjs';
import { qualifyMeasuredNativeLifecycle } from '../measured-native-lifecycle.mjs';
import { qualifyNativeProfileTransitions } from '../native-profile-transitions.mjs';
import { qualifyRepeatedNativeCandidateMeasurements } from '../repeated-native-candidate-measurement.mjs';

const fixture = () => {
  const f = repeatedLifecycleFixture();
  f.profileQualification = qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, {
    sequence: 'repeated240',
    requireFrameEvidence: true,
  });
  return f;
};
const qualify = (f) => qualifyMeasuredNativeLifecycle({ ...f, sequence: 'repeated240' });
const applied = (f) => f.quality.events.filter((e) => e.kind === 'applied');
const candidates = (f) => f.quality.events.filter((e) => e.kind === 'candidate');

test('shared raw lifecycle fixture independently satisfies both candidate and five-phase media gates', () => {
  const f = fixture();
  const result = qualifyRepeatedNativeCandidateMeasurements(f.candidateProof, {
    ...f,
    nativeProbe: f.probe,
  });
  assert.deepEqual(
    result.campaigns.map((c) => c.firstFrame),
    [750, 2550],
  );
  assert.equal(f.profileQualification.phases.length, 5);
});

test('joins all four repeated native profile applications with original revisions and event indices', () => {
  const f = fixture(),
    before = structuredClone(f);
  const r = qualify(f);
  assert.deepEqual(f, before);
  assert.equal(r.sequence, 'repeated240');
  assert.equal(r.applications.length, 4);
  assert.deepEqual(
    r.applications.map((a) => a.fromRevision),
    ['0', '1', '2', '3'],
  );
  assert.deepEqual(
    r.applications.map((a) => a.revision),
    ['1', '2', '3', '4'],
  );
  assert.deepEqual(
    r.applications.map((a) => a.qualityEventIndex),
    [1, 3, 4, 6],
  );
  assert.deepEqual(
    r.applications.map((a) => a.target),
    ['360p30', '240p30', '360p30', '240p30'],
  );
  assert.equal(r.nativeLifecycleReceiptsMatched, true);
  for (const flag of ['upgradeAuthorized', 'repeatedPolicyQualified', 'recoveryQualified'])
    assert.equal(r[flag], false);
});

test('repeated lifecycle can compute its own raw media replay without a supplied summary', () => {
  const f = fixture();
  delete f.profileQualification;
  assert.equal(qualify(f).applications.length, 4);
});

test('legacy lifecycle entry remains closed to repeated media', () => {
  assert.throws(() => qualifyMeasuredNativeLifecycle(fixture()));
});

test('reset may retain no historical measurement after native cancellation', () => {
  const f = fixture();
  f.lifecycle.profileRequests[1].candidateMeasurementID = null;
  f.lifecycle.profileRequests[3].candidateMeasurementID = null;
  assert.equal(qualify(f).applications.length, 4);
});

const mutations = {
  'unrecognized sequence': (f) => {
    f.sequence = 'anything';
  },
  'missing decoded evidence': (f) => {
    delete f.liveIDs;
  },
  'stale summary hides raw native corruption': (f) => {
    f.format.compressedFrames[0].byteCount = -1;
  },
  'fabricated media summary': (f) => {
    f.profileQualification.receipts = [];
  },
  'missing final request': (f) => {
    f.lifecycle.profileRequests.pop();
  },
  'unmatched extra bitrate write': (f) => {
    f.lifecycle.bitRateRequests.push(structuredClone(f.lifecycle.bitRateRequests.at(-1)));
  },
  'out of order bitrate writes': (f) => {
    [f.lifecycle.bitRateRequests[1], f.lifecycle.bitRateRequests[2]] = [
      f.lifecycle.bitRateRequests[2],
      f.lifecycle.bitRateRequests[1],
    ];
  },
  'wrong quality version': (f) => {
    f.quality.formatVersion = 3;
  },
  'unmeasured quality': (f) => {
    f.quality.measuredSourceEvaluationEnabled = false;
  },
  'missing second candidate event': (f) => {
    f.quality.events = f.quality.events.filter((e) => e !== candidates(f)[1]);
  },
  'extra candidate event': (f) => {
    f.quality.events.push(structuredClone(candidates(f)[1]));
  },
  'crossed candidate action': (f) => {
    candidates(f)[1].action.fromRevision = '0';
  },
  'closed second application': (f) => {
    applied(f)[2].closed = true;
  },
  'unsupported second action': (f) => {
    applied(f)[2].action.kind = 'bootstrap';
  },
  'reset with live candidate authority': (f) => {
    f.lifecycle.profileRequests[3].authorityPermitted = true;
  },
  'reset with live probe authority': (f) => {
    f.lifecycle.profileRequests[3].probeAuthorityPermitted = true;
  },
  'reset with active probe': (f) => {
    f.lifecycle.profileRequests[3].currentProbeActive = true;
  },
  'stale reset candidate from first cycle': (f) => {
    f.lifecycle.profileRequests[3].candidateMeasurementID =
      f.lifecycle.profileRequests[0].candidateMeasurementID;
  },
  'reused candidate identity across cycles': (f) => {
    const a = applied(f)[2],
      c = candidates(f)[1],
      old = applied(f)[0].application.candidateID;
    a.application.candidateID =
      a.action.candidateID =
      f.lifecycle.profileRequests[2].candidateMeasurementID =
      f.lifecycle.profileRequests[3].candidateMeasurementID =
        old;
    c.application.candidateID = c.action.candidateID = c.candidate.id = old;
  },
  'skipped original revision': (f) => {
    const a = applied(f)[2],
      c = candidates(f)[1];
    a.application.fromRevision =
      a.action.fromRevision =
      c.application.fromRevision =
      c.action.fromRevision =
        '8';
    a.revision = c.revision = '9';
  },
  'noncanonical original revision': (f) => {
    applied(f)[2].application.fromRevision = applied(f)[2].action.fromRevision = '02';
  },
  'second trial admitted before prior reset completion': (f) => {
    const a = applied(f)[2];
    a.application.admittedAt = 150;
    a.application.completionDeadline = 152;
  },
  'second trial request after action expiry': (f) => {
    applied(f)[2].action.validUntil = f.lifecycle.profileRequests[2].requestedAt - 0.001;
  },
  'quality global timeline regresses': (f) => {
    candidates(f)[0].at = 100;
  },
  'quality global timeline extends after closure': (f) => {
    candidates(f)[1].at = f.lifecycle.closedAt + 1;
  },
  'reused native configuration identity': (f) => {
    const config = f.lifecycle.bitRateRequests[1].receipt.configurationID;
    f.lifecycle.bitRateRequests[3].receipt.configurationID = applied(f)[2].receipt.configurationID =
      config;
    candidates(f)[1].receipt.configurationID = config;
  },
};
for (const [name, mutate] of Object.entries(mutations))
  test(`rejects repeated lifecycle ${name}`, () => {
    const f = fixture();
    mutate(f);
    if (name === 'unrecognized sequence') assert.throws(() => qualifyMeasuredNativeLifecycle(f));
    else assert.throws(() => qualify(f));
  });
