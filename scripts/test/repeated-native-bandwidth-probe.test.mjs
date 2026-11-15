import assert from 'node:assert/strict';
import test from 'node:test';
import {
  repeatedProbeScope as scope,
  repeatedNativeProbeEvidence as fixture,
} from './fixtures/repeated-probe-evidence.mjs';

// Keep the initial RED assertion about the missing behavior, not an import error.
const implementation = await import('../repeated-native-bandwidth-probe.mjs').catch((error) => {
  if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
  return {};
});
function qualify(proof) {
  assert.equal(
    typeof implementation.qualifyRepeatedNativeBandwidthProbe,
    'function',
    'repeated native verifier must be implemented',
  );
  return implementation.qualifyRepeatedNativeBandwidthProbe(proof, {
    scope,
    publishingGeneration: '7',
  });
}
const events = (p) => p.campaigns.flatMap((c) => c.events);
const campaign = (p) => p.campaigns[1];
const stage = (p, n = 3) => campaign(p).events.filter((e) => e.sample.stage === n);

for (const ending of ['observed', 'renewed', 'retired'])
  test(`qualifies actual native ${ending} terminal form without rewriting raw evidence`, () => {
    const proof = fixture(ending),
      before = structuredClone(proof),
      summary = qualify(proof);
    assert.deepEqual(proof, before);
    assert.equal(summary.mode, 'repeated');
    assert.equal(summary.receiverCapacityQualified, false);
    assert.equal(summary.repeatedPolicyQualified, false);
    assert.deepEqual(
      summary.campaigns.map((c) => c.campaign),
      ['1', '2'],
    );
    assert.deepEqual(
      summary.campaigns.map((c) => c.context.appliedRevision),
      ['0', '2'],
    );
    assert.deepEqual(
      summary.campaigns.map((c) => c.totalAcceptedPayloadBytes),
      [7896, 7896],
    );
    assert.deepEqual(
      summary.campaigns.map((c) => c.stages.map((s) => s.stage)),
      [
        [1, 2, 3],
        [1, 2, 3],
      ],
    );
    assert.deepEqual(summary.campaigns[1].context, proof.campaigns[1].context);
    assert.equal(summary.eventCount, events(proof).length);
  });

test('preserves a nonzero initial revision instead of rebasing to zero', () => {
  const proof = fixture();
  proof.campaigns[0].context.appliedRevision = '4';
  proof.campaigns[1].context.appliedRevision = '6';
  assert.deepEqual(
    qualify(proof).campaigns.map((c) => c.context.appliedRevision),
    ['4', '6'],
  );
});

const mutations = {
  wrongVersion: (p) => {
    p.formatVersion = 2;
  },
  wrongMode: (p) => {
    p.mode = 'staged';
  },
  open: (p) => {
    p.isClosed = false;
  },
  invalid: (p) => {
    p.invalid = true;
  },
  unfinished: (p) => {
    p.result = 'readinessUnavailable';
  },
  foreignScope: (p) => {
    p.scope.matchID = 'other';
  },
  generationMismatch: (p) => {
    p.publishingGeneration = '8';
  },
  extraTopLevelEvents: (p) => {
    p.events = [structuredClone(events(p)[0])];
  },
  missingCampaign: (p) => {
    p.campaigns.pop();
  },
  extraCampaign: (p) => {
    p.campaigns.push(structuredClone(campaign(p)));
  },
  campaignOrdinal: (p) => {
    campaign(p).campaign = '1';
  },
  unjoined: (p) => {
    campaign(p).isJoined = false;
  },
  incompleteStatus: (p) => {
    campaign(p).status = 'started';
  },
  wrongTerminalStatus: (p) => {
    campaign(p).status = 'completed';
  },
  staleRevision: (p) => {
    campaign(p).context.appliedRevision = '0';
  },
  malformedRevision: (p) => {
    campaign(p).context.appliedRevision = '02';
  },
  hugeRevision: (p) => {
    campaign(p).context.appliedRevision = '18446744073709551616';
  },
  changedGeneration: (p) => {
    campaign(p).context.publishingGeneration = '8';
  },
  wrongTarget: (p) => {
    campaign(p).context.targetProfile = '540p30';
  },
  wrongTargetRate: (p) => {
    campaign(p).context.targetBitRate = 800000;
  },
  wrongBaseline: (p) => {
    campaign(p).context.baselineProfile = '360p30';
  },
  wrongBaselineRate: (p) => {
    campaign(p).context.baselineBitRate = 400000;
  },
  invalidEncoder: (p) => {
    campaign(p).context.encoderSessionID = 'bad';
  },
  reusedEncoder: (p) => {
    campaign(p).context.encoderSessionID = p.campaigns[0].context.encoderSessionID;
  },
  reusedConfiguration: (p) => {
    campaign(p).context.configurationID = p.campaigns[0].context.configurationID;
  },
  invalidConfiguration: (p) => {
    campaign(p).context.configurationID = null;
  },
  futureAcknowledgment: (p) => {
    campaign(p).context.acknowledgedAt = 61;
  },
  oldAcknowledgment: (p) => {
    campaign(p).context.acknowledgedAt = 20;
  },
  staleReadiness: (p) => {
    campaign(p).context.healthyThrough = 57;
  },
  futureReadiness: (p) => {
    campaign(p).context.healthyThrough = 61;
  },
  reversedHealth: (p) => {
    campaign(p).context.healthySince = 60;
  },
  inheritedHealth: (p) => {
    campaign(p).context.healthySince = 20;
  },
  staleHealthSequence: (p) => {
    campaign(p).context.healthSequence = '100';
  },
  zeroHealthSequence: (p) => {
    campaign(p).context.healthSequence = '0';
  },
  missingContext: (p) => {
    delete campaign(p).context;
  },
  crossedCampaign: (p) => {
    stage(p)[1].sample.campaign = '1';
  },
  reusedStageID: (p) => {
    for (const e of stage(p)) e.sample.id = campaign(p).events[0].sample.id;
  },
  reusedCampaignID: (p) => {
    for (const e of stage(p, 1)) e.sample.id = p.campaigns[0].events[0].sample.id;
  },
  missingStage: (p) => {
    campaign(p).events = campaign(p).events.filter((e) => e.sample.stage !== 2);
  },
  reorderedStages: (p) => {
    campaign(p).events.reverse();
  },
  noRenewals: (p) => {
    campaign(p).events = campaign(p).events.filter((e) => e.phase !== 'renewed');
  },
  missingRetirement: (p) => {
    campaign(p).events.splice(3, 1);
  },
  missingFinal: (p) => {
    campaign(p).events.pop();
  },
  extraFinal: (p) => {
    campaign(p).events.push(structuredClone(campaign(p).events.at(-1)));
  },
  unknownEvent: (p) => {
    stage(p)[1].phase = 'ignored';
  },
  nonmonotonic: (p) => {
    stage(p)[2].observedAt = stage(p)[0].observedAt;
  },
  overlap: (p) => {
    for (const e of stage(p, 2)) e.sample.startedAt = 60.1;
  },
  counterReset: (p) => {
    stage(p)[1].sample.totalAcceptedPayloadBytes = '1316';
  },
  counterCarryOver: (p) => {
    for (const e of campaign(p).events)
      e.sample.totalAcceptedPayloadBytes = String(
        BigInt(e.sample.totalAcceptedPayloadBytes) + 7896n,
      );
  },
  unalignedBytes: (p) => {
    stage(p)[1].sample.acceptedPayloadBytes = '1317';
  },
  excessBudget: (p) => {
    stage(p)[1].sample.totalAcceptedPayloadBytes = '16778284';
  },
  malformedBytes: (p) => {
    stage(p)[1].sample.acceptedPayloadBytes = '01316';
  },
  changedOrigin: (p) => {
    stage(p)[1].sample.campaignStartedAt += 1;
  },
  excessDuration: (p) => {
    stage(p)[1].sample.leaseDeadline = 121;
  },
  acceptanceAfterLease: (p) => {
    stage(p)[1].sample.lastAcceptedAt = stage(p)[1].sample.leaseDeadline;
  },
  invalidReason: (p) => {
    campaign(p).events.at(-2).sample.reason = 'mystery';
  },
  unjoinedTerminal: (p) => {
    campaign(p).events.at(-1).sample.reason = null;
  },
  terminalNewBytes: (p) => {
    const s = campaign(p).events.at(-1).sample;
    s.acceptedPayloadBytes = '3948';
    s.totalAcceptedPayloadBytes = '9212';
  },
  terminalChangedLease: (p) => {
    campaign(p).events.at(-1).sample.leaseDeadline += 0.01;
  },
  terminalChangedTimestamp: (p) => {
    campaign(p).events.at(-1).sample.lastAcceptedAt += 0.001;
  },
  retirementOnFinal: (p) => {
    campaign(p).events.at(-1).retirementRequestedAt = 60.7;
  },
  renewalRevivesLease: (p) => {
    stage(p)[1].sample.leaseDeadline += 0.4;
  },
  changedLeaseOutsideRenewal: (p) => {
    campaign(p).events.at(-2).sample.leaseDeadline += 0.001;
  },
  malformedTime: (p) => {
    stage(p)[0].observedAt = NaN;
  },
  excessEvents: (p) => {
    campaign(p).events = Array.from({ length: 608 }, () => structuredClone(campaign(p).events[0]));
  },
};
for (const [name, mutate] of Object.entries(mutations))
  test(`rejects ${name}`, () => {
    const proof = fixture();
    mutate(proof);
    assert.equal(
      typeof implementation.qualifyRepeatedNativeBandwidthProbe,
      'function',
      'repeated native verifier must be implemented',
    );
    assert.throws(() => qualify(proof), /Repeated native probe/);
  });

test('rejects excess initial paced acceptance even within total byte budget', () => {
  const proof = fixture();
  const sample = campaign(proof).events[1].sample;
  sample.acceptedPayloadBytes = '131600';
  sample.totalAcceptedPayloadBytes = '131600';
  assert.equal(
    typeof implementation.qualifyRepeatedNativeBandwidthProbe,
    'function',
    'repeated native verifier must be implemented',
  );
  assert.throws(() => qualify(proof), /paced/);
});

test('retains each raw joined terminal event for independent lifecycle matching', () => {
  for (const ending of ['observed', 'renewed', 'retired']) {
    const proof = fixture(ending),
      summary = qualify(proof);
    for (let i = 0; i < 2; i++)
      for (const s of summary.campaigns[i].stages) {
        const raw = proof.campaigns[i].events.filter((e) => e.sample.stage === s.stage).at(-1);
        assert.deepEqual(s.terminalEvent, raw);
        assert.equal(s.terminalEvent.sample.campaign, summary.campaigns[i].campaign);
        assert.equal(s.retiredObservedAt, raw.observedAt);
      }
  }
});

function idleProof(messagesPerRenewal, burst = false) {
  const proof = fixture(),
    campaign = proof.campaigns[0],
    first = campaign.events[0].sample;
  const renewals = [];
  let accepted = 0,
    lastAcceptedAt = null;
  for (let n = 1; n <= 24; n++) {
    if (burst ? n === 12 : n > 10 && n <= 20) {
      accepted += messagesPerRenewal * 1316;
      lastAcceptedAt = first.startedAt + n * 0.1 - 0.01;
    }
    renewals.push({
      phase: 'renewed',
      observedAt: first.startedAt + n * 0.1 + 0.001,
      sample: {
        ...first,
        leaseDeadline: first.startedAt + n * 0.1 + 0.3,
        acceptedPayloadBytes: String(accepted),
        totalAcceptedPayloadBytes: String(accepted),
        lastAcceptedAt,
      },
    });
  }
  const remainder = campaign.events.filter((e) => e.sample.stage > 1);
  for (const event of remainder) {
    event.observedAt += 3;
    if (Object.hasOwn(event, 'retirementRequestedAt')) event.retirementRequestedAt += 3;
    event.sample.startedAt += 3;
    event.sample.leaseDeadline += 3;
    if (event.sample.lastAcceptedAt !== null) event.sample.lastAcceptedAt += 3;
    event.sample.totalAcceptedPayloadBytes = String(
      Number(event.sample.totalAcceptedPayloadBytes) + accepted - 2632,
    );
  }
  campaign.events = [
    campaign.events[0],
    ...renewals,
    {
      phase: 'retired',
      observedAt: first.startedAt + 2.42,
      retirementRequestedAt: first.startedAt + 2.41,
      sample: { ...renewals.at(-1).sample, reason: 'cancelled' },
    },
    ...remainder,
  ];
  return proof;
}
test('preserves native one-message token allowance without banking idle time', () => {
  assert.equal(qualify(idleProof(5, true)).campaigns[0].stages[0].acceptedPayloadBytes, 5 * 1316);
  assert.throws(() => qualify(idleProof(6, true)), /token budget/);
  assert.throws(() => qualify(idleProof(44, true)), /token budget/);
});
test('all earlier checkpoints bound repeated token allowance, not only adjacent observations', () => {
  assert.equal(qualify(idleProof(4)).campaigns[0].stages[0].acceptedPayloadBytes, 40 * 1316);
  assert.throws(() => qualify(idleProof(5)), /token budget/);
});
test('delayed observation uses native renewal instant for its token budget', () => {
  const proof = idleProof(5, true),
    events = proof.campaigns[0].events;
  events[11].observedAt = events[12].sample.lastAcceptedAt + 0.005;
  assert.equal(qualify(proof).campaigns[0].stages[0].acceptedPayloadBytes, 5 * 1316);
});

for (const key of ['policy', 'recoveryObservation'])
  test(`historical repeated proof rejects new ${key} metadata`, () => {
    const proof = fixture();
    proof.campaigns[0].events[1].sample[key] = null;
    assert.throws(() => qualify(proof));
  });
test('historical repeated proof rejects recovery root policy', () => {
  const proof = fixture();
  proof.policy = 'recovery-budget-v1';
  assert.throws(() => qualify(proof));
});

test('historical repeated qualifier rejects an explicitly requested unsupported policy', () => {
  for (const policy of ['recovery-budget-v1', 'future-v1', null])
    assert.throws(() =>
      implementation.qualifyRepeatedNativeBandwidthProbe(fixture(), {
        scope,
        publishingGeneration: '7',
        policy,
      }),
    );
});
