// @ts-check
import { spawn } from 'node:child_process';
import { createWriteStream } from 'node:fs';

/** @type {import('node:child_process').ChildProcess | undefined} */
let encoder;
let started = false;
let stopping = false;
let finished = false;
let parentDisconnected = false;
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
  parentDisconnected = true;
  for (const output of forwards) output.detach();
  stop();
}

function disconnect() {
  if (process.connected) process.disconnect?.();
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
  report({ event: 'exit', code, signal }, true);
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
    /** @type {{ type: string, binary: string, args: string[], stopTimeoutMs: number }} */ (
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
    // Guardian owns the encoder's readers: stdout is progress (parent fd1) and fd3 is
    // decoded PTS (parent fd4). Stderr is discarded; it echoes credentialed URLs.
    // Parent fd5 (the scorebug overlay feed) is shared, not copied, as the encoder's
    // stdin; only the parent writes it, so its EOF reaches FFmpeg.
    encoder = spawn(request.binary, request.args, { stdio: [5, 'pipe', 'ignore', 'pipe'] });
    forward(/** @type {import('node:stream').Readable} */ (encoder.stdout), 1);
    forward(/** @type {import('node:stream').Readable} */ (encoder.stdio[3]), 4);
    encoder.on('error', () => {
      report({ event: 'process_error' });
      if (!encoder?.pid) finish(null, null);
    });
    encoder.once('exit', (code, signal) => {
      // A descendant or stalled parent can retain an output after encoder exit.
      // Bound draining independently of stop(), retaining the actual exit status.
      drainTimer = setTimeout(() => {
        for (const output of forwards) {
          output.detach();
          output.closeSource();
        }
        void finish(code, signal);
      }, 250);
    });
    // Normally close joins all final pipe writes before reporting exit.
    encoder.once('close', finish);
  } catch {
    report({ event: 'spawn_failed' });
    finish(null, null);
  }
});
