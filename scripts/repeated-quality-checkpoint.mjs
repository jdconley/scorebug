import { qualifyTimingContract } from './native-timing-contract.mjs';
import assert from 'node:assert/strict';
import { isDeepStrictEqual } from 'node:util';

const identifier = (value) => {
  assert(typeof value === 'string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value));
  return value.toLowerCase();
};
const finite = (n) => typeof n === 'number' && Number.isFinite(n) && n >= 0;
const ownership = [
  'revision',
  'profileID',
  'receipt',
  'profileReceipt',
  'application',
  'acknowledgedAt',
];
const sameOwner = (a, b) => ownership.every((key) => isDeepStrictEqual(a[key], b[key]));
function hasTrialOwnership(trial) {
  const uuid = (value) =>
    typeof value === 'string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value);
  const receipt = trial.receipt,
    profile = trial.profileReceipt,
    application = trial.application;
  return (
    receipt &&
    profile &&
    application &&
    uuid(application.id) &&
    uuid(application.candidateID) &&
    uuid(receipt.configurationID) &&
    uuid(receipt.encoderSessionID) &&
    typeof receipt.generation === 'string' &&
    /^[1-9][0-9]*$/.test(receipt.generation) &&
    finite(receipt.acceptedAt) &&
    finite(receipt.bitRate) &&
    receipt.bitRate > 0 &&
    uuid(profile.encoderSessionID) &&
    uuid(profile.previousEncoderSessionID) &&
    profile.encoderSessionID === receipt.encoderSessionID &&
    profile.publishingGeneration === receipt.generation &&
    profile.profile === trial.profileID &&
    finite(profile.acknowledgedAt) &&
    finite(application.admittedAt) &&
    finite(application.completionDeadline) &&
    finite(trial.acknowledgedAt) &&
    trial.acknowledgedAt >=
      Math.max(receipt.acceptedAt, profile.acknowledgedAt, application.admittedAt) &&
    trial.acknowledgedAt <= application.completionDeadline
  );
}

/** Simulator fault scheduling only. A live controller confirmation is a causal
 * trigger, never independent evidence that the stream or recovery qualified.
 * Coalesced writes may skip polls, but retain the entire original event prefix.
 * The caller must bound file size and polling duration and join cancellation. */
export class RepeatedQualityCheckpoint {
  #attempt;
  #checkpoint;
  #claims = [];
  constructor(publishingAttemptID) {
    this.#attempt = identifier(publishingAttemptID);
  }
  observe(value) {
    qualifyTimingContract(value);
    qualifyTimingContract(value?.quality);
    assert.equal(value?.formatVersion, 1);
    assert.equal(value.mode, 'repeated');
    assert.equal(value.publishingAttemptID, this.#attempt);
    assert.equal(typeof value.closed, 'boolean');
    const quality = value.quality,
      events = quality?.events;
    assert.equal(quality?.formatVersion, 4);
    assert.equal(quality.overflow, false, 'Live quality overflow');
    for (const field of [
      'measuredSourceEvaluationEnabled',
      'decoderStallEnabled',
      'deadlineFailuresEnabled',
    ])
      assert.equal(quality[field], true);
    assert(Array.isArray(events) && events.length > 0 && events.length <= 512);
    assert(!events.some((event) => event.kind === 'failed'), 'Live quality failed');
    assert.equal(value.eventCount, events.length);
    assert.equal(events[0].kind, 'bootstrap');
    assert.equal(events[0].revision, '0');
    assert.equal(events[0].closed, false);
    // Session closure on a failed event differs from the joined checkpoint
    // boundary. Failures abort above; only stop finalizes a successful history.
    assert.equal(value.closed, events.at(-1).kind === 'stopped');
    assert.equal(events.at(-1).closed, value.closed);
    for (let i = 0; i < events.length; i++) {
      assert(finite(events[i].at));
      if (i) assert(events[i].at >= events[i - 1].at, 'Live event clock regressed');
      if (i < events.length - 1)
        assert.equal(events[i].closed, false, 'Event after terminal checkpoint');
    }
    if (value.closed) assert(['stopped', 'failed'].includes(events.at(-1).kind));
    const previous = this.#checkpoint;
    if (previous) {
      assert(events.length >= previous.eventCount, 'Live prefix regressed');
      assert.deepEqual(
        events.slice(0, previous.eventCount),
        previous.quality.events,
        'Original live prefix changed',
      );
      const { events: _old, ...oldFlags } = previous.quality;
      const { events: _new, ...newFlags } = quality;
      assert.deepEqual(newFlags, oldFlags);
      if (previous.closed) assert.deepEqual(value, previous, 'Checkpoint changed after closure');
    }
    this.#checkpoint = structuredClone(value);
  }
  claimNextReady() {
    const checkpoint = this.#checkpoint;
    if (!checkpoint || checkpoint.closed || this.#claims.length === 2) return null;
    const campaign = this.#claims.length + 1,
      revision = String(campaign * 2 - 1);
    const events = checkpoint.quality.events,
      latest = events.at(-1);
    if (latest.kind !== 'evaluated' || latest.revision !== revision || latest.state !== 'healthy')
      return null;
    const applied = events.filter((e) => e.kind === 'applied' && e.revision === revision);
    const candidates = events.filter((e) => e.kind === 'candidate' && e.revision === revision);
    const confirmed = events.filter(
      (e) =>
        e.kind === 'evaluated' && e.revision === revision && e.reasons?.includes('trialConfirmed'),
    );
    if (applied.length !== 1 || candidates.length !== 1 || confirmed.length !== 1) return null;
    const trial = applied[0],
      candidate = candidates[0],
      confirmation = confirmed[0];
    if (!hasTrialOwnership(trial)) return null;
    const baselineRevision = String(campaign * 2 - 2);
    if (
      trial.action?.kind !== 'trial' ||
      trial.action.fromRevision !== baselineRevision ||
      trial.application?.fromRevision !== baselineRevision ||
      trial.action.candidateID !== trial.application.candidateID ||
      !isDeepStrictEqual(candidate.action, trial.action)
    )
      return null;
    if (
      !sameOwner(latest, trial) ||
      !sameOwner(candidate, trial) ||
      !sameOwner(confirmation, trial)
    )
      return null;
    if (
      !trial.application?.candidateID ||
      candidate.candidate?.id !== trial.application.candidateID ||
      identifier(candidate.candidate.attemptID) !== this.#attempt
    )
      return null;
    const confirmedEventIndex = events.indexOf(confirmation),
      readyEventIndex = events.length - 1;
    if (
      events.indexOf(candidate) <= events.indexOf(trial) ||
      confirmedEventIndex <= events.indexOf(candidate) ||
      readyEventIndex <= confirmedEventIndex
    )
      return null;
    if (
      events
        .slice(confirmedEventIndex + 1)
        .some((e) => e.kind !== 'evaluated' || e.revision !== revision)
    )
      return null;
    const source = latest.source,
      window = latest.window;
    if (
      !source ||
      !window ||
      identifier(source.attemptID) !== this.#attempt ||
      window.revision !== revision ||
      ![
        source.start,
        source.end,
        window.start,
        window.end,
        confirmation.at,
        latest.evaluatedAt,
      ].every(finite) ||
      source.start !== window.start ||
      source.end !== window.end ||
      source.start <= confirmation.at ||
      source.end <= source.start ||
      source.end > latest.evaluatedAt
    )
      return null;
    if (
      campaign === 2 &&
      !events
        .slice(this.#claims[0].readyEventIndex, events.indexOf(trial))
        .some((e) => e.kind === 'applied' && e.revision === '2')
    )
      return null;
    const claim = {
      campaign: String(campaign),
      candidateID: identifier(candidate.candidate.id),
      trialRevision: revision,
      confirmedEventIndex,
      readyEventIndex,
    };
    this.#claims.push(structuredClone(claim));
    return claim;
  }
  reconcile(finalQuality) {
    assert(this.#checkpoint?.closed, 'Missing terminal live checkpoint');
    assert.equal(finalQuality?.events?.at(-1)?.kind, 'stopped');
    assert.deepEqual(
      finalQuality,
      this.#checkpoint.quality,
      'Final quality differs from live terminal history',
    );
    assert.equal(this.#claims.length, 2, 'Both fault campaigns must be claimed');
    return {
      liveCheckpointReconciled: true,
      campaigns: structuredClone(this.#claims),
      productionUpgradeAuthorized: false,
    };
  }
}
