// @ts-check
import { spawn } from 'node:child_process';
import { createWriteStream } from 'node:fs';
import { DecodedGeometry } from './decoded-geometry.mjs';
/** @type {DecodedGeometry | undefined} */
let decodedGeometry;
import { WorkerPacketTiming } from './worker-packet-timing.mjs';
/** @type {WorkerPacketTiming | undefined} */
let packetTiming;
import { EncoderDiagnostics, observeEncoderDiagnostics } from './encoder-diagnostics.mjs';
/** @type {EncoderDiagnostics | undefined} */
let diagnostics;

/** @type {import('node:child_process').ChildProcess | undefined} */
let encoder;
let started = false;
let stopping = false;
let finished = false;
let stopTimeoutMs = 5000;
/** @type {ReturnType<typeof setTimeout> | undefined} */
let killTimer;
/** @type {ReturnType<typeof setTimeout> | undefined} */
let drainTimer;
/** @type {{ detach: () => void, closeSource: () => void, drained: Promise<void> }[]} */
const forwards = [];

/**
 * Own the read side until the encoder exits. Parent loss must not turn its final
 * progress/telemetry writes into EPIPE and interrupt media finalization.
 * Normal piping uses stream backpressure; after parent loss data is discarded.
 * @param {import('node:stream').Readable} source
 * @param {number} fd
 */
function forward(source, fd) {
  const destination = createWriteStream('', { fd, autoClose: true });
  let detached = false;
  /** @type {Promise<void>} */
  const drained = new Promise((resolve) => {
    destination.once('close', () => resolve());
  });
  const detach = () => {
    if (detached) return;
    detached = true;
    source.unpipe(destination);
    destination.destroy();
    source.resume();
  };
  destination.on('error', () => {
    detach();
    stop();
  });
  source.on('error', () => {
    detach();
    stop();
  });
  forwards.push({ detach, closeSource: () => source.destroy(), drained });
  source.pipe(destination);
}

function detachParent() {
  for (const output of forwards) output.detach();
  stop();
}

function disconnect() {
  if (process.connected) process.disconnect();
}

/** @param {Record<string, unknown>} message */
function report(message, last = false) {
  if (!process.connected || !process.send) return;
  try {
    process.send(message, (error) => {
      if (last) disconnect();
      else if (error) stop();
    });
  } catch {
    if (last) disconnect();
    else stop();
  }
}

/** @param {number | null} code @param {NodeJS.Signals | null} signal */
async function finish(code, signal) {
  if (finished) return;
  finished = true;
  clearTimeout(killTimer);
  await Promise.all(forwards.map((output) => output.drained));
  clearTimeout(drainTimer);
  // A guardian exit is never substituted for the encoder's actual exit status.
  diagnostics?.end();
  packetTiming?.end();
  decodedGeometry?.end();
  report(
    {
      event: 'exit',
      code,
      signal,
      ...(diagnostics ? { diagnostics: diagnostics.snapshot() } : {}),
      ...(packetTiming ? { packetTiming: packetTiming.snapshot() } : {}),
      ...(decodedGeometry ? { decodedGeometry: decodedGeometry.snapshot() } : {}),
    },
    true,
  );
}

function alive() {
  return !finished && encoder?.exitCode === null && encoder.signalCode === null;
}

function stop() {
  if (stopping || finished) return;
  stopping = true;
  if (!alive()) return;
  report({ event: 'sigterm' });
  encoder?.kill('SIGTERM');
  killTimer = setTimeout(() => {
    if (!alive()) return;
    report({ event: 'sigkill' });
    encoder?.kill('SIGKILL');
  }, stopTimeoutMs);
}

// Install parent-loss handling before accepting any request to create an encoder.
process.on('disconnect', detachParent);
process.on('SIGTERM', stop);
process.on('SIGINT', stop);
process.on('message', (message) => {
  const request =
    /** @type {{ type: string, binary: string, args: string[], stopTimeoutMs: number, diagnostics?: boolean, packetTiming?: boolean, decodedGeometry?: boolean }} */ (
      message
    );
  if (request.type === 'stop') {
    stop();
    return;
  }
  if (request.type !== 'start' || started || stopping || !process.connected) return;
  started = true;
  stopTimeoutMs = request.stopTimeoutMs;
  try {
    // Guardian owns all encoder readers; parent fd4 is decoded telemetry and
    // fd5 is encoder timing. Raw diagnostics stay private to this process.
    diagnostics = request.diagnostics === true ? new EncoderDiagnostics() : undefined;
    packetTiming =
      diagnostics && request.packetTiming === true ? new WorkerPacketTiming() : undefined;
    decodedGeometry =
      diagnostics && request.decodedGeometry === true ? new DecodedGeometry() : undefined;
    encoder = spawn(request.binary, request.args, {
      stdio: ['ignore', 'pipe', diagnostics ? 'pipe' : 'ignore', 'pipe', 'pipe'],
    });
    forward(/** @type {import('node:stream').Readable} */ (encoder.stdout), 1);
    forward(/** @type {import('node:stream').Readable} */ (encoder.stdio[3]), 4);
    forward(/** @type {import('node:stream').Readable} */ (encoder.stdio[4]), 5);
    if (encoder.stderr && diagnostics) observeEncoderDiagnostics(encoder.stderr, diagnostics);
    if (encoder.stderr && packetTiming) {
      encoder.stderr.on('data', (chunk) => packetTiming?.push(chunk));
      encoder.stderr.on('error', () => packetTiming?.failPipe());
    }
    if (encoder.stderr && decodedGeometry) {
      encoder.stderr.on('data', (chunk) => decodedGeometry?.push(chunk));
      encoder.stderr.on('error', () => decodedGeometry?.failPipe());
    }
    encoder.on('error', () => {
      report({ event: 'process_error' });
      if (!encoder?.pid) finish(null, null);
    });
    encoder.once('exit', (code, signal) => {
      // A descendant or stalled parent can retain an output after encoder exit.
      // Bound draining independently of stop(), retaining the actual exit status.
      drainTimer = setTimeout(() => {
        diagnostics?.timeOutDrain();
        packetTiming?.timeOutDrain();
        decodedGeometry?.timeOutDrain();
        encoder?.stderr?.destroy();
        for (const output of forwards) {
          output.detach();
          output.closeSource();
        }
        void finish(code, signal);
      }, 250);
    });
    // Normally close joins all final diagnostic writes before reporting exit.
    encoder.once('close', finish);
  } catch {
    report({ event: 'spawn_failed' });
    finish(null, null);
  }
});
