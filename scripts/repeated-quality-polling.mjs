import assert from 'node:assert/strict';
import { isDeepStrictEqual } from 'node:util';
import { constants } from 'node:fs';
import { open } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { RepeatedQualityCheckpoint } from './repeated-quality-checkpoint.mjs';

const maximumBytes = 8 * 1024 * 1024;
/** Read one atomic simulator checkpoint; never follow a link or allocate from its advertised size. */
export async function readRepeatedCheckpoint(path) {
  let file;
  try {
    file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const stat = await file.stat();
    assert(stat.isFile(), 'Live checkpoint is not a regular file');
    assert(stat.size <= maximumBytes, 'Oversized live checkpoint');
    const bytes = Buffer.alloc(Math.min(stat.size + 1, maximumBytes + 1));
    let length = 0;
    while (length < bytes.length) {
      const result = await file.read(bytes, length, bytes.length - length, null);
      if (result.bytesRead === 0) break;
      length += result.bytesRead;
    }
    assert(length <= maximumBytes && length === stat.size, 'Oversized or changing live checkpoint');
    return JSON.parse(bytes.subarray(0, length).toString('utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  } finally {
    await file?.close();
  }
}

/** Bounded scheduling bridge, not a media qualification. The supplied reader
 * must itself be bounded and joined; a single 180s deadline spans both campaigns. */
export class RepeatedQualityPolling {
  #tracker;
  #scope;
  #claims = [];
  #read;
  #signal;
  #wait;
  #now;
  #deadline;
  #expected;
  #sourceOwner;
  constructor({
    publishingAttemptID,
    sourceOwner,
    matchID,
    broadcastGeneration,
    read,
    signal,
    now = () => performance.now(),
    wait = (ms) => delay(ms, undefined, { signal }),
  }) {
    this.#tracker = new RepeatedQualityCheckpoint(publishingAttemptID);
    assert(typeof matchID === 'string' && matchID.length > 0);
    assert(Number.isSafeInteger(broadcastGeneration) && broadcastGeneration > 0);
    assert(typeof read === 'function' && signal instanceof AbortSignal);
    assert(
      sourceOwner &&
        ['workerID', 'workerEpoch', 'readerID'].every(
          (key) => typeof sourceOwner[key] === 'string' && sourceOwner[key].length > 0,
        ) &&
        Number.isSafeInteger(sourceOwner.workerAttempt) &&
        sourceOwner.workerAttempt > 0,
      'Missing fixture source owner',
    );
    this.#sourceOwner = structuredClone(sourceOwner);
    this.#expected = {
      matchID,
      broadcastGeneration,
      publishingAttemptID: publishingAttemptID.toLowerCase(),
    };
    this.#read = read;
    this.#signal = signal;
    this.#wait = wait;
    this.#now = now;
    this.#deadline = now() + 180000;
  }
  get scope() {
    return structuredClone(this.#scope);
  }
  #check() {
    this.#signal.throwIfAborted();
    assert(this.#now() < this.#deadline, 'Repeated quality readiness timed out');
  }
  async #observe() {
    this.#check();
    const value = await this.#read();
    this.#check();
    if (value) {
      this.#tracker.observe(value);
      // The capture scope is independent of policy revisions. Bind its first
      // original queue event and preserve it across the complete prefix.
      for (const event of value.quality.events)
        if (event.evidence?.queue?.scope) this.#bindOriginalScope(event.evidence.queue.scope);
    }
    return value;
  }
  #bindScope(value) {
    const event = value.quality.events.at(-1);
    for (const key of ['workerID', 'workerEpoch', 'workerAttempt', 'readerID']) {
      const canonical = (value) =>
        ['workerEpoch', 'readerID'].includes(key) && typeof value === 'string'
          ? value.toLowerCase()
          : value;
      assert.equal(
        canonical(event.source?.[key]),
        canonical(this.#sourceOwner[key]),
        `Foreign ready source ${key}`,
      );
    }
    this.#bindOriginalScope(event.evidence?.queue?.scope);
  }
  #bindOriginalScope(scope) {
    assert(
      scope && typeof scope.recordingID === 'string' && scope.recordingID.length > 0,
      'Missing live recording scope',
    );
    for (const [key, expected] of Object.entries(this.#expected))
      assert.equal(
        key === 'publishingAttemptID' && typeof scope[key] === 'string'
          ? scope[key].toLowerCase()
          : scope[key],
        expected,
        `Foreign live ${key}`,
      );
    assert(
      typeof scope.appliedProfileRevision === 'string' &&
        /^(0|[1-9][0-9]*)$/.test(scope.appliedProfileRevision) &&
        BigInt(scope.appliedProfileRevision) <= 18446744073709551615n,
      'Invalid original capture scope revision',
    );
    if (this.#scope) assert.deepEqual(scope, this.#scope, 'Live scope changed');
    else this.#scope = structuredClone(scope);
  }
  async awaitReady(campaign) {
    assert.equal(campaign, String(this.#claims.length + 1), 'Unexpected repeated campaign');
    assert(this.#claims.length < 2, 'Too many repeated campaigns');
    for (;;) {
      const value = await this.#observe();
      if (value) {
        assert(!value.closed, 'Live quality closed before campaign readiness');
        const claim = this.#tracker.claimNextReady();
        if (claim) {
          assert.equal(claim.campaign, campaign);
          this.#bindScope(value);
          this.#claims.push(structuredClone(claim));
          return claim;
        }
      }
      await this.#wait(100);
    }
  }
  async validateReady(claim) {
    assert.deepEqual(claim, this.#claims.at(-1), 'Foreign or stale ready claim');
    const value = await this.#observe();
    assert(value && !value.closed, 'Live quality closed or missing before pause');
    const events = value.quality.events;
    assert(
      events
        .slice(claim.readyEventIndex)
        .every(
          (e) =>
            e.kind === 'evaluated' && e.revision === claim.trialRevision && e.state === 'healthy',
        ),
      'Live quality changed before pause',
    );
    const original = events[claim.readyEventIndex];
    for (const event of events.slice(claim.readyEventIndex)) {
      for (const key of [
        'revision',
        'profileID',
        'receipt',
        'profileReceipt',
        'application',
        'acknowledgedAt',
      ])
        assert.deepEqual(event[key], original[key], `Live trial ownership changed: ${key}`);
      for (const key of [
        'attemptID',
        'workerID',
        'workerEpoch',
        'workerAttempt',
        'readerID',
        'processingScopeID',
      ])
        assert.deepEqual(
          event.source?.[key],
          original.source[key],
          `Live source ownership changed: ${key}`,
        );
      assert.deepEqual(event.evidence?.queue?.scope, this.#scope, 'Live queue scope changed');
      const source = event.source,
        window = event.window;
      assert(
        source &&
          window &&
          window.revision === claim.trialRevision &&
          [source.start, source.end, window.start, window.end, event.evaluatedAt].every(
            (n) => typeof n === 'number' && Number.isFinite(n) && n >= 0,
          ) &&
          source.start === window.start &&
          source.end === window.end &&
          source.start > events[claim.confirmedEventIndex].at &&
          source.end > source.start &&
          source.end <= event.evaluatedAt,
        'Live source window changed before pause',
      );
    }
    this.#bindScope(value);
  }
  reconcile(terminal, finalQuality) {
    this.#tracker.observe(terminal);
    return this.#tracker.reconcile(finalQuality);
  }
}

/** Output may be present before authenticated relay ownership is correlated. */
export function repeatedFaultStatusReady(status, matchID) {
  const uuid = (value) =>
    typeof value === 'string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(value);
  const publication = status?.publication,
    observation = status?.observation,
    cadence = observation?.decoderCadence;
  return Boolean(
    status?.state === 'producing_output' &&
    status.gameId === matchID &&
    Number.isSafeInteger(status.generation) &&
    status.generation > 0 &&
    typeof status.workerId === 'string' &&
    status.workerId.length > 0 &&
    uuid(status.workerEpoch) &&
    uuid(publication?.publishingAttemptId) &&
    uuid(publication?.readerId) &&
    uuid(publication?.publisherId) &&
    Number.isSafeInteger(observation?.attempt) &&
    observation.attempt > 0 &&
    cadence?.formatVersion === 1 &&
    uuid(cadence.scopeID) &&
    cadence.ended === false &&
    cadence.invalidReason === null,
  );
}

export function repeatedFaultOwnerMatches(sample, original) {
  return (
    repeatedFaultStatusReady(sample, original.gameId) &&
    ['gameId', 'generation', 'workerId', 'workerEpoch'].every(
      (key) => sample[key] === original[key],
    ) &&
    sample.observation.attempt === original.observation.attempt &&
    sample.observation.decoderCadence.scopeID === original.observation.decoderCadence.scopeID &&
    isDeepStrictEqual(sample.publication, original.publication)
  );
}
