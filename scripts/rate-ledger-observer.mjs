import assert from 'node:assert/strict';

export const RATE_LEDGER_LIMITS = Object.freeze({
  maxOperations: 131072,
  maxBytes: 32 * 1024 * 1024,
  boundaryReserveBytes: 2 * 1024 * 1024,
});

// Operation rows contain only finite numbers, null, fixed ASCII labels and arrays.
// Number#toString has JSON's finite-number spelling, including -0 -> '0'. No
// event serialization or payload copying occurs on the queue's delivery path.
function rowBytes(value) {
  if (value === null) return 4;
  if (typeof value === 'number') return String(value).length;
  if (typeof value === 'string') return value.length + 2;
  return 2 + Math.max(0, value.length - 1) + value.reduce((n, item) => n + rowBytes(item), 0);
}

/** Passive, bounded recorder for one selected finite phase. A later finite phase
 * invalidates only the envelope: completed header/operations/footer never change.
 * Retention is bounded by 131072 rows (at most two small arrays per row) plus
 * header/footer FIFO arrays of at most 4096 four-number tuples each. No packet
 * payload or per-event strings are retained. 32 MiB is the serialized export
 * bound, not a claim about the JavaScript engine's heap representation.
 * Reduced limits are available to helper tests; the queue always uses fixed limits.
 */
export class RateLedgerObserver {
  #limits;
  #constructedRate;
  #finitePhaseCount;
  #header = null;
  #operations = [];
  #denial = null;
  #footer = null;
  #invalidReasons = [];
  #overflow = false;
  #operationBytes = 2; // surrounding []
  #active = false;
  constructor(configuration, limits = RATE_LEDGER_LIMITS) {
    assert.deepEqual(Object.keys(limits).sort(), Object.keys(RATE_LEDGER_LIMITS).sort());
    for (const key of Object.keys(RATE_LEDGER_LIMITS))
      assert.ok(
        Number.isSafeInteger(limits[key]) &&
          limits[key] > 0 &&
          limits[key] <= RATE_LEDGER_LIMITS[key],
      );
    assert.ok(limits.boundaryReserveBytes < limits.maxBytes);
    this.#limits = { ...limits };
    this.#constructedRate = configuration.rateBitsPerSecond;
    this.#finitePhaseCount = this.#constructedRate === null ? 0 : 1;
    if (this.#constructedRate !== null) this.#invalidate('initial-finite-rate');
  }
  #invalidate(reason) {
    if (!this.#invalidReasons.includes(reason)) this.#invalidReasons.push(reason);
  }
  get active() {
    return this.#active;
  }
  get recording() {
    return this.#active && !this.#overflow;
  }
  rateChange(previousRate, configuration, ordinal, at, tokens, state) {
    const rate = configuration.rateBitsPerSecond;
    if (this.#active) {
      this.record([ordinal, at, rate === null ? 'restore' : 'setRate', tokens, rate]);
      if (rate === null) this.finish(ordinal, at, tokens, state, true);
      else this.#invalidate('finite-rate-change');
      return;
    }
    if (rate === null) return;
    if (this.#header) {
      this.#invalidate('second-finite-phase');
      return;
    }
    this.#header = {
      configuration: { ...configuration },
      constructedRate: this.#constructedRate,
      initialFinitePhaseCount: this.#finitePhaseCount,
      limit: { ordinal, at },
      initialTokens: tokens,
      initialCounters: structuredClone(state.counters),
      initialFIFO: state.fifo,
    };
    if (previousRate !== null || this.#finitePhaseCount !== 0)
      this.#invalidate('prior-finite-phase');
    this.#finitePhaseCount++;
    this.#active = true;
    // Header and footer each fit well below half the fixed 2 MiB reserve: at most
    // 4096 FIFO tuples of four bounded numbers, six counter pairs, and config.
    if (Buffer.byteLength(JSON.stringify(this.#header)) > this.#limits.boundaryReserveBytes / 2)
      this.#overflow = true;
  }
  record(row) {
    if (!this.#active || this.#overflow) return;
    const bytes = rowBytes(row) + (this.#operations.length ? 1 : 0);
    if (
      this.#operations.length >= this.#limits.maxOperations ||
      this.#operationBytes + bytes > this.#limits.maxBytes - this.#limits.boundaryReserveBytes
    ) {
      this.#overflow = true;
      return;
    }
    this.#operations.push(row);
    this.#operationBytes += bytes;
  }
  denial(ordinal, at, id, wireBytes, tokens) {
    if (this.#active && !this.#overflow && this.#denial === null)
      this.#denial = { ordinal, at, id, wireBytes, tokens };
  }
  finish(ordinal, at, tokens, state, restored) {
    if (!this.#active) return;
    if (!restored) this.#invalidate('closed-before-restoration');
    this.#footer = {
      restoration: restored ? { ordinal, at } : null,
      finalFIFO: state.fifo,
      finalCounters: structuredClone(state.counters),
      finalTokens: tokens,
      operationCount: this.#operations.length,
      closed: restored,
      overflow: this.#overflow,
    };
    if (Buffer.byteLength(JSON.stringify(this.#footer)) > this.#limits.boundaryReserveBytes / 2) {
      this.#overflow = true;
      this.#footer.overflow = true;
    }
    this.#active = false;
  }
  firstDenialSnapshot() {
    return this.#denial === null ? null : { ...this.#denial };
  }
  snapshot() {
    if (!this.#header) return null;
    const envelope = {
      format: 'rate-ledger-v1',
      limits: this.#limits,
      header: this.#header,
      operations: [],
      denial: this.#denial,
      footer: this.#footer,
      overflow: this.#overflow,
      invalidReasons: this.#invalidReasons,
    };
    // Count the complete export exactly, including keys, limits, flags and the
    // witness. Only the small envelope is serialized; rows use incremental byte
    // accounting. If an undersized helper budget cannot hold even its boundaries,
    // withhold the proof entirely rather than emit an oversized/truncated ledger.
    const bytes = Buffer.byteLength(JSON.stringify(envelope)) + this.#operationBytes - 2;
    if (bytes > this.#limits.maxBytes) {
      this.#overflow = true;
      return null;
    }
    return structuredClone({ ...envelope, operations: this.#operations });
  }
}
