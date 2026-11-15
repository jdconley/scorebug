import assert from 'node:assert/strict';
import test from 'node:test';
import { repeatedMeasuredRecoveryFaultFixture as fixture } from './fixtures/repeated-measured-recovery-fault-evidence.mjs';
import { qualifyMeasuredRecoveryFault } from '../measured-recovery-fault.mjs';
import { qualifyNativeStallSignal } from '../native-controlled-stall.mjs';
const implementation = await import('../repeated-measured-recovery-fault.mjs').catch((e) => {
  if (e.code !== 'ERR_MODULE_NOT_FOUND') throw e;
  return {};
});
function qualify(f) {
  assert.equal(
    typeof implementation.qualifyRepeatedMeasuredRecoveryFaults,
    'function',
    'repeated fault qualifier must exist',
  );
  return implementation.qualifyRepeatedMeasuredRecoveryFaults(f);
}
const trigger = (f, n = 1) =>
  f.quality.events.filter((e) => e.kind === 'decoderStall' || e.kind === 'deliveryFailure')[n];
const reset = (f, n = 1) =>
  f.quality.events.filter((e) => e.kind === 'applied' && e.action?.kind === 'reset')[n];
test('two original confirmed revisions bind distinct pauses to native phases1/3 and resets2/4', () => {
  const f = fixture(),
    before = structuredClone(f),
    r = qualify(f);
  assert.deepEqual(f, before);
  assert.equal(r.faultQualified, true);
  for (const key of ['recoveryQualified', 'repeatedPolicyQualified', 'productionUpgradeAuthorized'])
    assert.equal(r[key], false);
  assert.deepEqual(
    r.campaigns.map((c) => [c.campaign, c.trialRevision, c.resetRevision, c.prePauseSourceFrame]),
    [
      ['1', '1', '2', 1760],
      ['2', '3', '4', 3560],
    ],
  );
  for (const c of r.campaigns) {
    assert.equal(f.quality.events[c.triggerEventIndex].revision, c.trialRevision);
    assert.equal(f.quality.events[c.resetEventIndex].revision, c.resetRevision);
  }
});
test('legacy fault and stall routes remain closed to repeated envelopes and revision3', () => {
  const f = fixture();
  assert.throws(() =>
    qualifyMeasuredRecoveryFault({ ...f, fault: f.faults, prefix: f.confirmations[0] }),
  );
  assert.throws(
    () =>
      qualifyNativeStallSignal(
        {
          quality: f.quality,
          audit: f.cadenceReports,
          fault: f.faults.campaigns[1],
          scope: f.scope,
          expectedRevision: '3',
        },
        trigger(f),
      ),
    /Unsupported stall revision/,
  );
});
const mutations = {
  version: (f) => {
    f.faults.formatVersion = 1;
  },
  mode: (f) => {
    f.faults.mode = 'single';
  },
  open: (f) => {
    f.faults.closed = false;
  },
  failed: (f) => {
    f.faults.failed = true;
  },
  scope: (f) => {
    f.faults.scope = { ...f.scope, matchID: 'other' };
  },
  missingCampaign: (f) => {
    f.faults.campaigns.pop();
  },
  extraCampaign: (f) => {
    f.faults.campaigns.push(structuredClone(f.faults.campaigns[1]));
  },
  crossCampaign: (f) => {
    f.faults.campaigns[1].campaign = '1';
  },
  crossCandidate: (f) => {
    f.faults.campaigns[1].candidateID = f.faults.campaigns[0].candidateID;
  },
  crossRevision: (f) => {
    f.faults.campaigns[1].trialRevision = '1';
  },
  crossConfirmation: (f) => {
    f.faults.campaigns[1].confirmedEventIndex = f.confirmations[0].confirmedEventIndex;
  },
  staleRawEventCount: (f) => {
    f.confirmations[1].rawEventCount--;
  },
  missingConfirmation: (f) => {
    f.quality.events[f.confirmations[1].confirmedEventIndex].reasons = [];
  },
  wrongConfirmationRevision: (f) => {
    f.confirmations[1].trialRevision = '1';
  },
  wrongBaselineRevision: (f) => {
    f.confirmations[1].appliedRevision = '0';
  },
  missingTrigger: (f) => {
    f.quality.events.splice(f.quality.events.indexOf(trigger(f)), 1);
  },
  extraTrigger: (f) => {
    f.quality.events.splice(-1, 0, structuredClone(trigger(f)));
  },
  reversedTimeline: (f) => {
    trigger(f).at = 100;
  },
  nonImmediateReset: (f) => {
    f.quality.events.splice(f.quality.events.indexOf(reset(f)), 0, {
      ...structuredClone(trigger(f)),
      kind: 'evaluated',
    });
  },
  triggerBeforeConfirmation: (f) => {
    trigger(f).evaluatedAt = 200;
  },
  crossTrialReceipt: (f) => {
    trigger(f).receipt.configurationID = trigger(f, 0).receipt.configurationID;
  },
  wrongResetRevision: (f) => {
    reset(f).revision = '2';
  },
  wrongResetAuthority: (f) => {
    reset(f).action.fromRevision = '1';
  },
  wrongResetSequence: (f) => {
    reset(f).application.windowSequence = '1';
  },
  lateReset: (f) => {
    reset(f).application.admittedAt = reset(f).action.validUntil + 0.001;
  },
  wrongExpiry: (f) => {
    reset(f).action.validUntil += 1;
  },
  overlappingPauses: (f) => {
    f.faults.campaigns[1].pauseSentAt = f.faults.campaigns[0].pauseSentAt + 1000;
    f.faults.campaigns[1].resumeSentAt = f.faults.campaigns[1].pauseSentAt + 2000;
  },
  changedProcess: (f) => {
    f.faults.campaigns[1].identity.decoder.start = '2040-01-01T00:00:03Z';
  },
  changedWorker: (f) => {
    f.faults.campaigns[1].pausedSample.value.context.workerEpoch =
      'ffffffff-ffff-4fff-8fff-ffffffffffff';
  },
  crossPausedPTS: (f) => {
    f.faults.campaigns[1].pausedSample.value.decoderCadence.progress.lastFreshPTS =
      f.faults.campaigns[0].pausedSample.value.decoderCadence.progress.lastFreshPTS;
  },
  beforeOutsidePause: (f) => {
    f.faults.campaigns[1].beforePauseSample.receivedAt = f.faults.campaigns[1].pauseSentAt + 1;
  },
  staleBefore: (f) => {
    f.faults.campaigns[1].beforePauseSample.value.decoderCadenceAgeUpperBoundMs = 300;
  },
  staleNativeSignal: (f) => {
    trigger(f).decoderStall.observedAtLowerBound -= 0.3;
  },
  wrongSourceSummary: (f) => {
    f.sourceIntervalQualification.intervals[1].decodedFrames--;
  },
  sourceBeforeConfirmation: (f) => {
    f.snapshot.sourceIntervals[1].captureBoundaryStartTime = 200;
  },
  wrongPhase: (f) => {
    f.profileQualification.phases[3].width = 426;
  },
  foreignEncoder: (f) => {
    f.profileQualification.phases[3].encoderSessionID =
      f.profileQualification.phases[1].encoderSessionID;
  },
  missingArchive: (f) => {
    f.archiveIDs = f.archiveIDs.filter((x) => x !== 3560);
  },
  missingLive: (f) => {
    f.liveIDs = f.liveIDs.filter((x) => x !== 3560);
  },
  noResumption: (f) => {
    f.cadenceReports.rows.pop();
  },
  missingStop: (f) => {
    f.quality.events.pop();
  },
  extraFaultMetadata: (f) => {
    f.faults.events = [];
  },
  invalidPID: (f) => {
    f.faults.campaigns[1].identity.decoder.ppid = 10;
  },
  missingStart: (f) => {
    delete f.faults.campaigns[1].identity.decoder.start;
  },
  wrongBinary: (f) => {
    f.faults.campaigns[1].identity.decoder.command = '/bin/sleep';
  },
};
for (const [name, mutate] of Object.entries(mutations))
  test(`rejects repeated fault ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.equal(
      typeof implementation.qualifyRepeatedMeasuredRecoveryFaults,
      'function',
      'repeated fault qualifier must exist',
    );
    assert.throws(() => qualify(f));
  });

const { repeatedMeasuredDeliveryFaultFixture, repeatedFaultDeliveryRow } =
  await import('./fixtures/repeated-measured-recovery-fault-evidence.mjs');
const { qualifyNativeDeliveryDeadlines } = await import('../native-delivery-deadlines.mjs');
for (const routes of [
  ['deliveryFailure', 'deliveryFailure'],
  ['decoderStall', 'deliveryFailure'],
  ['deliveryFailure', 'decoderStall'],
])
  test(`preserves original global indices with routes ${routes.join('/')}`, () => {
    const f = repeatedMeasuredDeliveryFaultFixture(routes),
      r = qualify(f);
    assert.deepEqual(
      r.campaigns.map((c) => c.triggerKind),
      routes,
    );
    for (const c of r.campaigns)
      assert.equal(f.quality.events[c.triggerEventIndex].revision, c.trialRevision);
  });
for (const duration of [1, 2])
  test(`raw helper independently validates a healthy ${duration}s delivery lane`, () => {
    const f = fixture(),
      { row, report } = repeatedFaultDeliveryRow(f, {
        revision: '1',
        start: 140,
        end: 140 + duration,
        evaluatedAt: 142 + duration,
      });
    const result = qualifyNativeDeliveryDeadlines({
      audit: {
        formatVersion: 1,
        closed: true,
        overflow: false,
        invalid: false,
        latencyBudget: 1.5,
        maximumSampleAge: 0.25,
        rows: [row],
      },
      reports: { ...f.cadenceReports, rows: [report] },
      cadenceAuditMode: 'repeated',
      scope: f.scope,
      expectedLatencyBudget: 1.5,
    });
    assert.equal(result.observations.healthyRows, 1);
    assert.equal(result.counts.onTimeFrames, 30 * duration);
  });
test('first fault cannot borrow second-cycle resumed progress', () => {
  const f = fixture();
  f.cadenceReports.rows.splice(2, 1);
  assert.throws(() => qualify(f), /resum/i);
});
test('resumed progress must retain the original decoder worker ownership', () => {
  const f = fixture();
  f.cadenceReports.rows[2].response.status.workerEpoch = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
  assert.throws(() => qualify(f), /owner/i);
});

test('reset profile receipt must match the actual independently qualified native phase', () => {
  const f = fixture();
  reset(f).profileReceipt = { ...reset(f).profileReceipt, width: 960 };
  assert.throws(() => qualify(f), /native profile receipt/i);
});

for (const kind of ['application', 'profileReceipt', 'acknowledgedAt'])
  test(`confirmation and trigger cannot jointly substitute the original trial ${kind}`, () => {
    const f = fixture();
    const confirmed = f.quality.events[f.confirmations[1].confirmedEventIndex];
    const failed = trigger(f);
    for (const event of [confirmed, failed]) {
      if (kind === 'application') event.application.id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
      else if (kind === 'profileReceipt') event.profileReceipt.width = 960;
      else event.acknowledgedAt += 0.001;
    }
    assert.throws(() => qualify(f), /original trial/);
  });

test('candidate decision cannot substitute the actual native trial application', () => {
  const f = fixture();
  const candidate = f.quality.events.filter((e) => e.kind === 'candidate')[1];
  candidate.application.id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
  assert.throws(() => qualify(f), /original trial/);
});

test('candidate decision cannot precede its actual native trial event', () => {
  const f = fixture();
  const candidate = f.quality.events.filter((e) => e.kind === 'candidate')[1];
  const applied = f.quality.events.find((e) => e.kind === 'applied' && e.revision === '3');
  candidate.at = applied.at - 0.001;
  f.quality.events.sort((a, b) => a.at - b.at);
  assert.throws(() => qualify(f), /original trial/);
});
