// @ts-check
import { spawn } from 'node:child_process';
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
function finish(code, signal) {
  if (finished) return;
  finished = true;
  clearTimeout(killTimer);
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
process.on('disconnect', stop);
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
    // Inherit the output descriptor directly: a broken worker pipe cannot crash
    // the guardian before it kills/reaps the encoder. Diagnostics contain URLs.
    // Parent fd4 is decoded telemetry and fd5 is encoder timing; IPC stays fd3.
    diagnostics = request.diagnostics === true ? new EncoderDiagnostics() : undefined;
    packetTiming =
      diagnostics && request.packetTiming === true ? new WorkerPacketTiming() : undefined;
    decodedGeometry =
      diagnostics && request.decodedGeometry === true ? new DecodedGeometry() : undefined;
    encoder = spawn(request.binary, request.args, {
      stdio: ['ignore', 'inherit', diagnostics ? 'pipe' : 'ignore', 4, 5],
    });
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
      if (!diagnostics) {
        finish(code, signal);
        return;
      }
      // A descendant may retain stderr after the actual encoder exits. Preserve
      // that exit status and bound diagnostic drain independently of stop().
      drainTimer = setTimeout(() => {
        diagnostics?.timeOutDrain();
        packetTiming?.timeOutDrain();
        decodedGeometry?.timeOutDrain();
        encoder?.stderr?.destroy();
        finish(code, signal);
      }, 250);
    });
    // Normally close joins all final diagnostic writes before reporting exit.
    encoder.once('close', finish);
  } catch {
    report({ event: 'spawn_failed' });
    finish(null, null);
  }
});
