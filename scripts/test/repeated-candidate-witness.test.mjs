import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import * as implementation from '../measured-candidate-witness.mjs';
import { repeatedReceiverIntervalFixture } from './fixtures/repeated-receiver-interval-evidence.mjs';
import { withRepeatedAdmissionWitnesses } from './fixtures/repeated-admission-witnesses.mjs';
import { qualifyRepeatedNativeCandidateMeasurements } from '../repeated-native-candidate-measurement.mjs';

const fixture = () => {
  const f = withRepeatedAdmissionWitnesses(repeatedReceiverIntervalFixture());
  f.candidates = qualifyRepeatedNativeCandidateMeasurements(f.candidateProof, {
    ...f,
    nativeProbe: f.probe,
  });
  // Unit boundary input; the combined admission tests replay the independent
  // interval gate instead of supplying this coverage result directly.
  f.intervalQualification = {
    mode: 'repeated',
    coveredIntervalIndexes: f.intervals.intervals.map((_, i) => i),
  };
  return f;
};
const decisions = (f) => f.quality.events.filter((e) => e.kind === 'candidate');
const args = (f, index = 1) => ({
  witness: decisions(f)[index].candidateAdmission,
  candidateProof: f.candidateProof.campaigns[index].measurement,
  candidate: f.candidates.campaigns[index],
  intervals: f.intervals,
  intervalQualification: f.intervalQualification,
  nativeProof: f.probe,
  campaign: String(index + 1),
  quality: f.quality,
});
const qualify = (f, index = 1) => {
  assert.equal(
    typeof implementation.qualifyRepeatedCandidateWitness,
    'function',
    'Repeated witness replay is required',
  );
  return implementation.qualifyRepeatedCandidateWitness(args(f, index));
};

test('replays both original campaign witnesses with global interval and baseline indices', () => {
  const f = fixture(),
    before = structuredClone(f);
  const results = [qualify(f, 0), qualify(f, 1)];
  assert.deepEqual(f, before);
  assert.deepEqual(
    results.map((r) => r.campaign),
    ['1', '2'],
  );
  assert.deepEqual(
    results.map((r) => r.appliedRevision),
    ['0', '2'],
  );
  assert.deepEqual(
    results.map((r) => r.baselineEventIndex),
    [0, 3],
  );
  assert.deepEqual(
    results.map((r) => r.qualityEventIndex),
    [2, 5],
  );
  assert.deepEqual(
    results.map((r) => r.selectedIntervalIndexes),
    [
      [2, 3],
      [6, 7],
    ],
  );
  for (const r of results) {
    assert.equal(r.witnessQualified, true);
    assert.equal(r.headroomQualified, true);
    assert.equal(r.mediaHealthQualified, false);
    assert.equal(r.upgradeAuthorized, false);
  }
});

test('legacy witness route rejects a mislabeled v3 native proof', () => {
  const f = JSON.parse(
    fs.readFileSync(
      new URL('./fixtures/measured-candidate-witness-diagnostic-a.json', import.meta.url),
    ),
  );
  f.nativeProof.formatVersion = 3;
  assert.throws(() => implementation.qualifyMeasuredCandidateWitness(f));
});

test('legacy witness route rejects native campaign metadata', () => {
  const f = JSON.parse(
    fs.readFileSync(
      new URL('./fixtures/measured-candidate-witness-diagnostic-a.json', import.meta.url),
    ),
  );
  f.witness.binding.campaign = '1';
  f.candidateProof.probeBinding.initial.campaign = '1';
  assert.throws(() => implementation.qualifyMeasuredCandidateWitness(f));
});

const faults = {
  'stale revision zero': (f) => {
    decisions(f)[1].candidateAdmission.applied.revision = '0';
  },
  'bootstrap used for second baseline': (f) => {
    decisions(f)[1].candidateAdmission.applied.receipt = structuredClone(
      f.quality.events[0].receipt,
    );
  },
  'crossed measurement campaign': (f) => {
    f.candidates.campaigns[1].campaign = '1';
  },
  'crossed native bound campaign': (f) => {
    decisions(f)[1].candidateAdmission.binding.campaign = '1';
  },
  'crossed native current campaign': (f) => {
    decisions(f)[1].candidateAdmission.probe.campaign = '1';
  },
  'missing native current campaign': (f) => {
    delete decisions(f)[1].candidateAdmission.probe.campaign;
  },
  'crossed selected row campaign': (f) => {
    f.intervals.intervals[6].nativeProbeCampaign = '1';
  },
  'crossed endpoint campaign': (f) => {
    decisions(f)[1].candidateAdmission.intervals[0].start.campaign = '1';
  },
  'crossed expectation campaign': (f) => {
    decisions(f)[1].candidateAdmission.intervals[0].end.expected.campaign = '1';
  },
  'missing independent coverage': (f) => {
    f.intervalQualification.coveredIntervalIndexes = [0, 1, 2, 3];
  },
  'wrong independent coverage mode': (f) => {
    f.intervalQualification.mode = 'staged';
  },
  'reused first pair': (f) => {
    decisions(f)[1].candidateAdmission.intervals = structuredClone(
      decisions(f)[0].candidateAdmission.intervals,
    );
  },
  'missing second baseline event': (f) => {
    f.quality.events.splice(3, 1);
  },
  'second baseline is trial': (f) => {
    f.quality.events[3].action.kind = 'trial';
  },
  'wrong native context configuration': (f) => {
    f.probe.campaigns[1].context.configurationID = f.probe.campaigns[0].context.configurationID;
  },
  'native events from first campaign': (f) => {
    f.probe.campaigns[1].events = f.probe.campaigns[0].events;
  },
  'malformed raw native history': (f) => {
    f.probe.campaigns[1].events[2].sample.acceptedPayloadBytes = '999';
  },
  'fabricated covered index': (f) => {
    f.intervalQualification.coveredIntervalIndexes.push(1000);
  },
  'altered witness payload rate': (f) => {
    decisions(f)[1].candidateAdmission.deliveredPaddingBitsPerSecond++;
  },
  'altered witness cost': (f) => {
    decisions(f)[1].candidateAdmission.candidateTransportBitsPerSecond++;
  },
  'later deadline': (f) => {
    decisions(f)[1].candidateAdmission.validUntil += 0.01;
  },
  'future receiver pair': (f) => {
    f.intervals.intervals[7].evaluatedAt = decisions(f)[1].candidate.evaluatedAt + 1;
  },
};
for (const [name, mutate] of Object.entries(faults))
  test(`rejects repeated witness ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });
