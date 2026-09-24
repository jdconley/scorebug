import { constants } from 'node:os';
// Deliberately fixed diagnostic allowlists. This module loads before the native
// runner builds protocol/dist, and must not depend on generated workspace files.
const WORKER_STATES = [
  'idle',
  'waiting_source',
  'starting',
  'producing_output',
  'stopping',
  'retrying',
  'failed',
  'closed',
];
const WORKER_REASONS = [
  'assignment_changed',
  'source_unavailable',
  'output_mismatch',
  'control_unavailable',
  'control_timeout',
  'output_timeout',
  'process_exited',
  'score_write_failed',
  'start_failed',
  'retry_budget',
  'retry_delay',
  'shutdown',
];
const DECODED_VIDEO_INVALID_REASONS = [
  'framing',
  'numeric',
  'ordinal',
  'oversized',
  'incomplete',
  'callback',
  'clock',
  'overflow',
];

const pipelineEvents = new Set([
  'ffmpeg_spawning',
  'ffmpeg_exited',
  'ffmpeg_sigterm',
  'ffmpeg_sigkill',
  'ffmpeg_process_error',
  'ffmpeg_spawn_failed',
  'ffmpeg_guardian_connection_failed',
  'ffmpeg_guardian_lost',
  'ffmpeg_progress_callback_failed',
  'ffmpeg_terminal_callback_failed',
]);
const integer = (value) => Number.isSafeInteger(value);
const count = (value) => integer(value) && value >= 0;
const positive = (value) => count(value) && value > 0;
const object = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const uuid = (value) =>
  typeof value === 'string' && /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(value);
const signal = (value) =>
  value === null || (typeof value === 'string' && Object.hasOwn(constants.signals, value));
const increment = (value) => Math.min(Number.MAX_SAFE_INTEGER, value + 1);
function requireValue(condition) {
  if (!condition) throw new Error('invalid_evidence');
}
function exit(value) {
  requireValue(
    object(value) && (value.code === null || integer(value.code)) && signal(value.signal),
  );
  return { code: value.code, signal: value.signal };
}
function scope(value) {
  requireValue(uuid(value.gameId) && positive(value.generation) && positive(value.pipelineOrdinal));
  return {
    gameId: value.gameId,
    generation: value.generation,
    pipelineOrdinal: value.pipelineOrdinal,
  };
}
function diagnostics(value) {
  const keys = [
    'inputReadError',
    'outputOpenError',
    'connectionRefused',
    'connectionTimeout',
    'ioError',
    'invalidData',
    'corruptPacket',
    'decodeError',
    'endOfFile',
  ];
  requireValue(
    object(value) && object(value.counts) && keys.every((key) => count(value.counts[key])),
  );
  requireValue(
    count(value.unmatchedLines) &&
      count(value.oversizedLines) &&
      typeof value.incompleteLine === 'boolean' &&
      typeof value.ended === 'boolean',
  );
  // Older runs did not classify these messages. Absence is not a zero count.
  for (const key of ['missingReference', 'invalidSlice', 'concealment']) {
    if (Object.hasOwn(value.counts, key)) {
      requireValue(count(value.counts[key]));
      keys.push(key);
    }
  }
  const flags = {};
  // Earlier diagnostic fixtures lack these fields; absence remains explicit.
  for (const key of ['pipeError', 'drainTimedOut']) {
    if (value[key] !== undefined) {
      requireValue(typeof value[key] === 'boolean');
      flags[key] = value[key];
    }
  }
  return {
    ...flags,
    counts: Object.fromEntries(keys.map((key) => [key, value.counts[key]])),
    unmatchedLines: value.unmatchedLines,
    oversizedLines: value.oversizedLines,
    incompleteLine: value.incompleteLine,
    ended: value.ended,
  };
}
function terminal(value) {
  const d = value.decodedVideo;
  requireValue(
    object(d) &&
      ['acceptedFrames', 'freshFrames', 'duplicateFrames', 'reorderedFrames'].every((key) =>
        count(d[key]),
      ),
  );
  requireValue(d.acceptedFrames === d.freshFrames + d.duplicateFrames + d.reorderedFrames);
  requireValue(
    ['firstPTS', 'lastPTS', 'highestPTS'].every((key) =>
      d.acceptedFrames ? integer(d[key]) : d[key] === null,
    ),
  );
  requireValue(!d.acceptedFrames || (d.highestPTS >= d.firstPTS && d.highestPTS >= d.lastPTS));
  requireValue(
    d.timeBase === '1/90000' &&
      typeof d.ended === 'boolean' &&
      (d.invalidReason === null || DECODED_VIDEO_INVALID_REASONS.includes(d.invalidReason)),
  );
  requireValue(typeof value.telemetryEOF === 'boolean');
  let outputProgress = null;
  if (value.outputProgress !== null) {
    requireValue(
      object(value.outputProgress) &&
        count(value.outputProgress.frame) &&
        count(value.outputProgress.outTimeUs),
    );
    outputProgress = {
      frame: value.outputProgress.frame,
      outTimeUs: value.outputProgress.outTimeUs,
    };
  }
  return {
    decodedVideo: Object.fromEntries(
      [
        'acceptedFrames',
        'freshFrames',
        'duplicateFrames',
        'reorderedFrames',
        'firstPTS',
        'lastPTS',
        'highestPTS',
        'timeBase',
        'invalidReason',
        'ended',
      ].map((key) => [key, d[key]]),
    ),
    telemetryEOF: value.telemetryEOF,
    encoderExit: value.encoderExit === null ? null : exit(value.encoderExit),
    outputProgress,
    ...(value.diagnostics === undefined ? {} : { diagnostics: diagnostics(value.diagnostics) }),
  };
}
function packetTiming(value) {
  requireValue(
    value.formatVersion === 1 &&
      value.diagnosticOnly === true &&
      value.maximumPacketsPerLane === 128,
  );
  requireValue(['demux', 'mux'].includes(value.stage) && ['video', 'audio'].includes(value.media));
  requireValue(
    ['ended', 'pipeError', 'drainTimedOut', 'incompleteLine'].every(
      (key) => typeof value[key] === 'boolean',
    ),
  );
  requireValue(
    ['malformedRows', 'oversizedLines', 'packetCount', 'retainedPackets', 'firstPacketIndex'].every(
      (key) => count(value[key]),
    ),
  );
  requireValue(value.retainedPackets === Math.min(128, value.packetCount));
  requireValue(
    value.firstPacketIndex % 8 === 0 && value.firstPacketIndex < Math.max(1, value.retainedPackets),
  );
  requireValue(
    Array.isArray(value.packets) &&
      value.packets.length === Math.min(8, value.retainedPackets - value.firstPacketIndex),
  );
  const packets = value.packets.map((packet) => {
    requireValue(object(packet));
    for (const key of ['pts', 'dts']) {
      requireValue(typeof packet[key] === 'string' && /^-?(?:0|[1-9]\d{0,18})$/.test(packet[key]));
      requireValue(BigInt(packet[key]) > -(1n << 63n) && BigInt(packet[key]) < 1n << 63n);
    }
    for (const key of ['ptsSeconds', 'dtsSeconds'])
      requireValue(
        typeof packet[key] === 'string' &&
          /^-?\d{1,20}(?:\.\d{1,20})?(?:e[+-]?\d{1,3})?$/.test(packet[key]) &&
          Number.isFinite(Number(packet[key])),
      );
    return Object.fromEntries(
      ['pts', 'ptsSeconds', 'dts', 'dtsSeconds'].map((key) => [key, packet[key]]),
    );
  });
  return {
    ...Object.fromEntries(
      [
        'formatVersion',
        'diagnosticOnly',
        'maximumPacketsPerLane',
        'ended',
        'pipeError',
        'drainTimedOut',
        'incompleteLine',
        'malformedRows',
        'oversizedLines',
        'stage',
        'media',
        'firstPacketIndex',
        'packetCount',
        'retainedPackets',
      ].map((key) => [key, value[key]]),
    ),
    packets,
  };
}
function event(value) {
  requireValue(object(value));
  if (value.msg === 'worker_state') {
    requireValue(WORKER_STATES.includes(value.state));
    const result = { msg: value.msg, state: value.state };
    if (value.reason !== undefined) {
      requireValue(WORKER_REASONS.includes(value.reason));
      result.reason = value.reason;
    }
    if (value.gameId !== undefined || value.generation !== undefined) {
      requireValue(uuid(value.gameId) && positive(value.generation));
      result.gameId = value.gameId;
      result.generation = value.generation;
    }
    return result;
  }
  if (value.msg === 'worker_packet_timing')
    return { msg: value.msg, ...scope(value), ...packetTiming(value) };
  if (value.msg === 'worker_pipeline_terminal')
    return { msg: value.msg, ...scope(value), ...terminal(value) };
  if (!pipelineEvents.has(value.msg)) return null;
  return { msg: value.msg, ...scope(value), ...(value.msg === 'ffmpeg_exited' ? exit(value) : {}) };
}

/** Only bounded, allowlisted scalar evidence survives; raw logs never enter artifacts. */
export class NativeWorkerEvidence {
  #pending = '';
  #dropping = false;
  #ended = false;
  #result = {
    events: [],
    discardedLines: 0,
    invalidLines: 0,
    oversizedLines: 0,
    omittedEvents: 0,
    incompleteLine: false,
  };
  push(chunk) {
    if (this.#ended) return;
    for (const byte of chunk) {
      if (byte === 10) {
        if (!this.#dropping) this.#line(this.#pending);
        this.#pending = '';
        this.#dropping = false;
      } else if (!this.#dropping) {
        if (this.#pending.length < 4096) this.#pending += String.fromCharCode(byte);
        else {
          this.#pending = '';
          this.#dropping = true;
          this.#result.oversizedLines = increment(this.#result.oversizedLines);
        }
      }
    }
  }
  #line(line) {
    try {
      const clean = event(JSON.parse(line));
      if (!clean) {
        this.#result.discardedLines = increment(this.#result.discardedLines);
        return;
      }
      if (this.#result.events.length === 256) {
        this.#result.omittedEvents = increment(this.#result.omittedEvents);
        return;
      }
      this.#result.events.push({ sequence: this.#result.events.length + 1, ...clean });
    } catch {
      this.#result.invalidLines = increment(this.#result.invalidLines);
    }
  }
  end() {
    if (this.#ended) return;
    this.#ended = true;
    this.#result.incompleteLine = this.#pending.length > 0 || this.#dropping;
    this.#pending = '';
  }
  snapshot() {
    return structuredClone(this.#result);
  }
}

/** Attach before yielding after spawn. Save is memoized and always joins actual child close. */
export function observeNativeWorkerEvidence(child, persist) {
  const collector = new NativeWorkerEvidence();
  let workerError = false,
    stdoutEnded = false,
    workerExit;
  const fixtureSignals = [];
  child.stdout?.on('data', (chunk) => collector.push(chunk));
  child.stdout?.once('end', () => {
    stdoutEnded = true;
    collector.end();
  });
  child.once('error', () => {
    workerError = true;
  });
  const closed = new Promise((resolve) =>
    child.once('close', (code, closeSignal) => {
      collector.end();
      workerExit = exit({ code, signal: closeSignal });
      resolve();
    }),
  );
  let saving;
  return {
    closed,
    signal(value) {
      requireValue(value === 'SIGTERM' || value === 'SIGKILL');
      if (fixtureSignals.length < 2) fixtureSignals.push(value);
      child.kill(value);
    },
    save() {
      saving ??= closed.then(() =>
        persist({
          formatVersion: 1,
          ...collector.snapshot(),
          workerError,
          stdoutEnded,
          workerExit,
          fixtureSignals: [...fixtureSignals],
        }),
      );
      return saving;
    },
  };
}
