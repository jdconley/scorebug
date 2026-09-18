import assert from 'node:assert/strict';
import { candidateHeadroomStageRates } from './native-candidate-headroom.mjs';

const check = (condition, message) => assert.ok(condition, `Repeated native probe: ${message}`);
const time = (value) => typeof value === 'number' && Number.isFinite(value) && value >= 0;
const uuid = (value) =>
  typeof value === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(value);
const uint = (value, positive = false) => {
  check(
    typeof value === 'string' && /^(0|[1-9][0-9]{0,19})$/.test(value),
    'malformed decimal counter',
  );
  const parsed = BigInt(value);
  check(
    parsed <= 18446744073709551615n && (!positive || parsed > 0n),
    'counter outside unsigned range',
  );
  return parsed;
};
const bytes = (value) => {
  const parsed = uint(value);
  check(
    parsed <= 16n * 1024n * 1024n && parsed % 1316n === 0n,
    'counter exceeds aligned campaign budget',
  );
  return parsed;
};

/** Replays raw v3 native acceptance and joined ownership. Readiness is only
 * metadata here: the complete health, reset, candidate, and profile evidence
 * must be independently joined by the combined verifier before policy success.
 * Native totalAcceptedPayloadBytes is campaign-local, including at restart. */
export function qualifyRepeatedNativeBandwidthProbe(proof, { scope, publishingGeneration } = {}) {
  check(
    proof?.formatVersion === 3 && proof.mode === 'repeated',
    'requires explicit v3 repeated export',
  );
  check(
    proof.isClosed === true && proof.invalid === false && proof.result === 'completed',
    'requires closed completed valid proof',
  );
  check(!Object.hasOwn(proof, 'events'), 'unexpected unowned top-level events');
  assert.deepEqual(proof.scope, scope, 'Repeated native probe: publication scope mismatch');
  check(uuid(scope?.publishingAttemptID), 'invalid publication attempt');
  uint(publishingGeneration, true);
  check(proof.publishingGeneration === publishingGeneration, 'publishing generation mismatch');
  check(
    Array.isArray(proof.campaigns) && proof.campaigns.length === 2,
    'requires exactly two campaigns',
  );
  const campaigns = [],
    identities = new Set();
  let previous;
  for (const [index, campaign] of proof.campaigns.entries()) {
    check(campaign?.campaign === String(index + 1), 'campaign ordinal mismatch');
    check(
      campaign.isJoined === true && ['completed', 'withdrawn'].includes(campaign.status),
      'campaign must be complete and joined',
    );
    const context = campaign.context;
    check(
      context && typeof context === 'object' && !Array.isArray(context),
      'missing readiness context',
    );
    const revision = uint(context.appliedRevision),
      sequence = uint(context.healthSequence, true);
    check(
      context.publishingGeneration === publishingGeneration &&
        context.targetProfile === '360p30' &&
        context.targetBitRate === 600_000 &&
        context.baselineProfile === '240p30' &&
        context.baselineBitRate === 350_000,
      'readiness generation or profile mismatch',
    );
    check(
      uuid(context.encoderSessionID) && uuid(context.configurationID),
      'malformed readiness configuration',
    );
    check(
      [context.acknowledgedAt, context.healthySince, context.healthyThrough].every(time) &&
        context.healthySince < context.healthyThrough &&
        context.acknowledgedAt <= context.healthyThrough,
      'invalid readiness chronology',
    );
    check(
      Array.isArray(campaign.events) &&
        campaign.events.length >= 9 &&
        campaign.events.length <= 607,
      'event count outside bounds',
    );
    const origin = campaign.events[0]?.sample?.startedAt;
    check(
      time(origin) && context.healthyThrough <= origin && origin - context.healthyThrough <= 2,
      'readiness is stale or future at campaign start',
    );
    if (previous) {
      check(
        revision > uint(previous.context.appliedRevision) &&
          sequence > uint(previous.context.healthSequence),
        'stale applied revision or health sequence',
      );
      check(
        context.encoderSessionID.toLowerCase() !==
          previous.context.encoderSessionID.toLowerCase() &&
          context.configurationID.toLowerCase() !== previous.context.configurationID.toLowerCase(),
        'reused baseline configuration',
      );
      check(
        origin > previous.campaignStartedAt &&
          origin >= previous.joinedObservedAt &&
          context.acknowledgedAt > previous.joinedObservedAt &&
          context.healthySince >= previous.joinedObservedAt,
        'campaign overlaps prior ownership or inherits old readiness',
      );
    }
    let cursor = 0,
      priorTime = previous?.joinedObservedAt ?? -1,
      cumulative = 0n,
      lastRetired;
    const stages = [];
    for (const [rateIndex, bitRate] of candidateHeadroomStageRates.entries()) {
      const stage = rateIndex + 1,
        checkpoints = [];
      let first,
        prior,
        priorBytes = 0n,
        priorTotal = cumulative;
      function read(phase) {
        const event = campaign.events[cursor++],
          value = event?.sample;
        check(
          event?.phase === phase && value && typeof value === 'object',
          `expected ${phase} for stage ${stage}`,
        );
        check(time(event.observedAt) && event.observedAt >= priorTime, 'nonmonotonic observation');
        check(
          value.campaign === campaign.campaign &&
            value.stage === stage &&
            value.bitRate === bitRate &&
            value.publishingGeneration === publishingGeneration,
          'campaign, stage, rate, or generation mismatch',
        );
        check(uuid(value.id), 'malformed stage identity');
        check(
          time(value.startedAt) &&
            value.startedAt >= origin &&
            value.startedAt < origin + 60 &&
            value.startedAt <= event.observedAt &&
            value.campaignStartedAt === origin,
          'invalid start or campaign origin',
        );
        check(
          time(value.leaseDeadline) &&
            value.leaseDeadline > value.startedAt &&
            value.leaseDeadline <= origin + 60.3 + 1e-6,
          'invalid lease deadline',
        );
        const accepted = bytes(value.acceptedPayloadBytes),
          total = bytes(value.totalAcceptedPayloadBytes);
        check(
          accepted >= priorBytes &&
            total >= priorTotal &&
            total >= accepted &&
            total - priorTotal === accepted - priorBytes,
          'inconsistent local and cumulative byte deltas',
        );
        check(
          (value.lastAcceptedAt === null) === (accepted === 0n),
          'acceptance timestamp and count disagree',
        );
        if (accepted > 0n) {
          check(
            time(value.lastAcceptedAt) &&
              value.lastAcceptedAt >= value.startedAt &&
              value.lastAcceptedAt <= event.observedAt &&
              value.lastAcceptedAt < value.leaseDeadline &&
              value.lastAcceptedAt < origin + 60,
            'acceptance outside observation, lease, or campaign',
          );
          check(
            Number(accepted / 1316n) * 10880 <=
              (value.lastAcceptedAt - value.startedAt) * bitRate + 1,
            'acceptance exceeds paced accounting budget',
          );
        }
        check(value.reason === null || value.reason === 'cancelled', 'unexpected terminal reason');
        if (phase === 'retired') {
          check(
            value.reason === 'cancelled' &&
              time(event.retirementRequestedAt) &&
              event.retirementRequestedAt >= priorTime &&
              event.retirementRequestedAt <= event.observedAt,
            'invalid retirement request',
          );
        } else
          check(
            !Object.hasOwn(event, 'retirementRequestedAt'),
            'retirement request on non-retirement event',
          );
        if (prior) {
          check(
            value.id.toLowerCase() === first.id.toLowerCase() &&
              value.startedAt === first.startedAt,
            'changed current-stage identity',
          );
          if (prior.reason !== null)
            assert.deepEqual(value, prior, 'Repeated native probe: changed terminal snapshot');
          if (accepted === priorBytes)
            check(
              value.lastAcceptedAt === prior.lastAcceptedAt,
              'changed timestamp without acceptance',
            );
          else
            for (const checkpoint of checkpoints)
              check(
                value.lastAcceptedAt >= checkpoint.at &&
                  Number((accepted - checkpoint.accepted) / 1316n) * 10880 <=
                    (value.lastAcceptedAt - checkpoint.at) * bitRate + 10881,
                'acceptance exceeds one-message token budget',
              );
          // A renewal can observe an already-cancelled snapshot without renewing
          // its lease. Only an actual lease advance requires a renewal instant.
          if (
            (phase === 'renewed' && value.reason === null) ||
            value.leaseDeadline !== prior.leaseDeadline
          ) {
            const renewedAt = value.leaseDeadline - 0.3;
            check(
              phase === 'renewed' &&
                value.leaseDeadline >= prior.leaseDeadline &&
                renewedAt >= priorTime - 1e-6 &&
                renewedAt <= event.observedAt + 1e-6 &&
                renewedAt < prior.leaseDeadline &&
                renewedAt < origin + 60,
              'renewal instant outside observations, old lease, or campaign',
            );
          }
        } else {
          check(
            value.reason === null && accepted === 0n && total === cumulative,
            'stage must start empty at exact prior retired total',
          );
          check(
            Math.abs(value.leaseDeadline - value.startedAt - 0.3) < 1e-6,
            'stage must start with a 300-ms lease',
          );
          check(!identities.has(value.id.toLowerCase()), 'reused stage identity');
          identities.add(value.id.toLowerCase());
          if (lastRetired)
            check(
              value.startedAt >= lastRetired.observedAt,
              'replacement overlaps prior retirement',
            );
          first = value;
        }
        checkpoints.push({
          at: Math.max(value.leaseDeadline - 0.3, value.lastAcceptedAt ?? first.startedAt),
          accepted,
        });
        prior = value;
        priorBytes = accepted;
        priorTotal = total;
        priorTime = event.observedAt;
        return event;
      }
      read(stage === 1 ? 'began' : 'replaced');
      let renewals = 0;
      while (campaign.events[cursor]?.phase === 'renewed' && prior.reason === null) {
        read('renewed');
        renewals++;
      }
      check(
        renewals > 0 && priorBytes > 0n,
        'every stage requires renewal and positive acceptance',
      );
      let terminal;
      if (stage < 3 || campaign.status === 'completed') {
        check(prior.reason === null, 'premature stage withdrawal');
        terminal = read('retired');
        lastRetired = terminal;
      } else {
        if (prior.reason === null) read('observed');
        check(prior.reason === 'cancelled', 'withdrawal lacks terminal observation');
        terminal = read('final');
      }
      cumulative = priorTotal;
      stages.push({
        campaign: campaign.campaign,
        stage,
        id: first.id.toLowerCase(),
        publishingGeneration,
        bitRate,
        startedAt: first.startedAt,
        campaignStartedAt: origin,
        acceptedPayloadBytes: Number(priorBytes),
        totalAcceptedPayloadBytes: Number(cumulative),
        lastAcceptedAt: prior.lastAcceptedAt,
        reason: prior.reason,
        terminalPhase: terminal.phase,
        terminalEvent: structuredClone(terminal),
        retiredObservedAt: terminal.observedAt,
        ...(terminal.phase === 'retired'
          ? { retirementRequestedAt: terminal.retirementRequestedAt }
          : {}),
      });
    }
    check(cursor === campaign.events.length, 'unconsumed events after joined terminal');
    previous = {
      campaign: campaign.campaign,
      status: campaign.status,
      isJoined: true,
      context: { ...context },
      campaignStartedAt: origin,
      joinedObservedAt: priorTime,
      acceptedPayloadBytes: Number(cumulative),
      totalAcceptedPayloadBytes: Number(cumulative),
      stages,
      eventCount: cursor,
    };
    campaigns.push(previous);
  }
  return {
    mode: 'repeated',
    formatVersion: 3,
    schedule: 'candidate-headroom-v1',
    publishingGeneration,
    campaigns,
    eventCount: campaigns.reduce((sum, campaign) => sum + campaign.eventCount, 0),
    receiverCapacityQualified: false,
    repeatedPolicyQualified: false,
  };
}
