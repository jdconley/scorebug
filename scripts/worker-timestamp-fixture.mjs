import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { DecodedVideoParser } from '../apps/home-daemon/src/decoded-video.ts';

/** Explicit finite-fixture helper: use the production fd3, never parse stderr. */
export async function runInstrumentedWorker(binary, args, diagnostics = {}) {
  const pts = [];
  diagnostics.pts = pts;
  diagnostics.stderr = '';
  let invalid;
  const parser = new DecodedVideoParser(
    (value) => {
      if (pts.length >= 10_000) {
        invalid = 'Finite fixture exceeded frame bound';
        child.kill('SIGKILL');
        return;
      }
      pts.push(value);
    },
    (reason) => {
      invalid = reason;
    },
  );
  const child = spawn(binary, args, { stdio: ['ignore', 'ignore', 'pipe', 'pipe'] });
  const onData = (chunk) => parser.push(chunk);
  child.stdio[3].on('data', onData);
  const onStderr = (chunk) => {
    const remaining = 64 * 1024 - Buffer.byteLength(diagnostics.stderr);
    if (remaining > 0) diagnostics.stderr += chunk.subarray(0, remaining).toString();
  };
  child.stderr.on('data', onStderr);
  const timeout = setTimeout(() => {
    diagnostics.timedOut = true;
    child.kill('SIGKILL');
  }, 20_000);
  try {
    const code = await new Promise((resolve) => {
      child.once('error', (error) => {
        diagnostics.spawnError = String(error);
      });
      child.once('close', (exitCode, signal) => {
        diagnostics.terminal = { code: exitCode, signal };
        resolve(exitCode);
      });
    });
    parser.end();
    diagnostics.invalid = invalid;
    assert.equal(code, 0, `Instrumented worker failed: ${diagnostics.stderr.slice(-2000).trim()}`);
    assert.equal(invalid, undefined, 'Invalid decoder telemetry');
    return pts;
  } finally {
    clearTimeout(timeout);
    child.stdio[3].removeListener('data', onData);
    child.stderr.removeListener('data', onStderr);
  }
}
