import assert from 'node:assert/strict';
import { isDeepStrictEqual } from 'node:util';
import { setTimeout as delay } from 'node:timers/promises';
import {
  inventoryDecoderProcesses,
  resolveDecoderIdentity,
  revalidateDecoderIdentity,
} from './owned-decoder-stall.mjs';

const uuid = (value) =>
  typeof value === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(value);
const text = (value) => typeof value === 'string' && value.length > 0;
function validateScope(scope) {
  assert(
    scope &&
      text(scope.recordingID) &&
      text(scope.matchID) &&
      Number.isSafeInteger(scope.broadcastGeneration) &&
      scope.broadcastGeneration > 0 &&
      typeof scope.publishingAttemptID === 'string' &&
      uuid(scope.publishingAttemptID.toLowerCase()) &&
      typeof scope.appliedProfileRevision === 'string' &&
      /^(0|[1-9][0-9]*)$/.test(scope.appliedProfileRevision) &&
      BigInt(scope.appliedProfileRevision) <= 0xffffffffffffffffn,
    'Invalid original repeated fault scope',
  );
}
function captureClaim(value, campaign, previous) {
  assert(
    value &&
      value.campaign === campaign &&
      value.trialRevision === (campaign === '1' ? '1' : '3') &&
      uuid(value.candidateID),
    'Invalid repeated fault claim',
  );
  for (const key of ['confirmedEventIndex', 'readyEventIndex']) {
    assert(
      Number.isSafeInteger(value[key]) && value[key] >= 0 && value[key] < 512,
      'Invalid original confirmation index',
    );
  }
  assert(value.readyEventIndex >= value.confirmedEventIndex, 'Readiness precedes confirmation');
  if (previous) {
    assert(value.candidateID !== previous.candidateID, 'Reused fault candidate');
    assert(
      value.confirmedEventIndex > previous.readyEventIndex,
      'Second confirmation did not advance original history',
    );
  }
  return Object.freeze({
    campaign,
    candidateID: value.candidateID,
    trialRevision: value.trialRevision,
    confirmedEventIndex: value.confirmedEventIndex,
    readyEventIndex: value.readyEventIndex,
  });
}
function validateSample(sample, scope, previous) {
  const value = sample?.value,
    context = value?.context,
    cadence = value?.decoderCadence;
  assert(
    context &&
      context.gameId === scope.matchID &&
      context.generation === scope.broadcastGeneration &&
      context.publication?.publishingAttemptId === scope.publishingAttemptID.toLowerCase() &&
      text(context.workerId) &&
      uuid(context.workerEpoch) &&
      Number.isSafeInteger(context.attempt) &&
      context.attempt > 0 &&
      uuid(context.publication.readerId) &&
      uuid(context.publication.publisherId),
    'Owned fault worker/publication scope changed',
  );
  assert(
    cadence?.formatVersion === 1 &&
      uuid(cadence.scopeID) &&
      cadence.ended === false &&
      cadence.invalidReason === null &&
      Number.isSafeInteger(cadence.progress?.lastFreshPTS) &&
      cadence.progress.lastFreshPTS >= 0,
    'Invalid owned decoder progress',
  );
  if (previous) {
    assert.deepEqual(context, previous.value.context, 'Owned worker/publication changed');
    assert.equal(
      cadence.scopeID,
      previous.value.decoderCadence.scopeID,
      'Owned decoder scope changed',
    );
  }
  return cadence.progress.lastFreshPTS;
}
/** Two confirmation-driven lab faults. Readiness is an external bounded check,
 * never permission inferred from elapsed time. All times remain Node-local;
 * original native event indexes are retained only as causal join metadata. */
export async function runRepeatedOwnedDecoderStalls({
  worker,
  signal,
  scope,
  awaitReady,
  validateReady,
  observeBeforePause,
  observePaused,
  save,
  inventory: read = inventoryDecoderProcesses,
  revalidate = read === inventoryDecoderProcesses
    ? revalidateDecoderIdentity
    : async (identity) =>
        resolveDecoderIdentity(await read(identity.worker.pid), identity.worker.pid),
  signalProcess = (pid, kind) => process.kill(pid, kind),
  wait = (ms) => delay(ms, undefined, { signal }),
  now = () => performance.now(),
}) {
  const evidence = {
    formatVersion: 2,
    mode: 'repeated',
    scope: structuredClone(scope),
    closed: false,
    failed: false,
    campaigns: [],
  };
  const persist = () => save(structuredClone(evidence));
  const alive = () =>
    assert(
      Number.isSafeInteger(worker?.pid) &&
        worker.pid > 0 &&
        worker.exitCode === null &&
        worker.signalCode === null,
      'Owned worker exited',
    );
  const active = () => {
    signal?.throwIfAborted();
    alive();
  };
  const sample = async (observe, campaign) => {
    const requestStartedAt = now();
    const value = structuredClone(await observe(campaign));
    return { requestStartedAt, receivedAt: now(), value };
  };
  let failure;
  try {
    validateScope(evidence.scope);
    assert(
      typeof awaitReady === 'function' &&
        typeof observeBeforePause === 'function' &&
        typeof observePaused === 'function' &&
        typeof save === 'function',
      'Missing repeated fault callbacks',
    );
    for (const campaign of ['1', '2']) {
      active();
      const previous = evidence.campaigns.at(-1);
      const claim = captureClaim(await awaitReady(campaign), campaign, previous);
      active();
      const row = {
        ...claim,
        closed: false,
        failed: false,
        identity: null,
        pauseSentAt: null,
        resumeSentAt: null,
      };
      evidence.campaigns.push(row);
      let paused = false,
        campaignFailure;
      try {
        row.identity = resolveDecoderIdentity(await read(worker.pid), worker.pid);
        if (previous)
          assert.deepEqual(row.identity, previous.identity, 'Owned process identity changed');
        active();
        row.beforePauseSample = await sample(observeBeforePause, campaign);
        const beforePTS = validateSample(
          row.beforePauseSample,
          evidence.scope,
          previous?.pausedSample,
        );
        if (previous)
          assert(
            beforePTS > previous.pausedSample.value.decoderCadence.progress.lastFreshPTS,
            'New pause inherits previous stalled progress',
          );
        active();
        if (validateReady) await validateReady(claim);
        active();
        // No asynchronous work separates scoped identity validation from SIGSTOP.
        const current = await revalidate(structuredClone(row.identity));
        active();
        assert(
          isDeepStrictEqual(current, row.identity),
          'Owned decoder identity changed before pause',
        );
        signalProcess(current.decoder.pid, 'SIGSTOP');
        paused = true;
        row.pauseSentAt = now();
        await persist();
        active();
        await wait(1800);
        active();
        row.pausedSample = await sample(observePaused, campaign);
        const pausedPTS = validateSample(row.pausedSample, evidence.scope, row.beforePauseSample);
        assert(pausedPTS >= beforePTS, 'Paused decoder progress regressed');
        active();
      } catch (error) {
        campaignFailure = error;
      } finally {
        if (paused) {
          try {
            // Cancellation must not suppress resume; only the same owned tree may receive it.
            alive();
            const current = resolveDecoderIdentity(await read(worker.pid), worker.pid);
            alive();
            assert(
              isDeepStrictEqual(current, row.identity),
              'Owned decoder identity changed while paused',
            );
            signalProcess(current.decoder.pid, 'SIGCONT');
            row.resumeSentAt = now();
          } catch (error) {
            campaignFailure ??= error;
          }
        }
        try {
          active();
        } catch (error) {
          campaignFailure ??= error;
        }
        row.closed = true;
        row.failed = Boolean(campaignFailure);
      }
      if (campaignFailure) throw campaignFailure;
      await persist();
      active();
    }
  } catch (error) {
    failure = error;
  } finally {
    evidence.closed = true;
    evidence.failed = Boolean(failure);
    try {
      await persist();
      signal?.throwIfAborted();
    } catch (error) {
      failure ??= error;
      evidence.failed = true;
      // A failed terminal write must not leave the last persisted envelope
      // looking successful. Retry once with terminal failure, preserving the
      // original error even when storage remains unavailable.
      try {
        await persist();
        signal?.throwIfAborted();
      } catch {
        /* Caller still receives failure. */
      }
    }
  }
  if (failure) throw failure;
  return evidence;
}
