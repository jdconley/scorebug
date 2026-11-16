import { execFile, spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

/** The server's signing key in tests. It is never a bearer token. */
export const scoringTestSecret = 'qa-server-secret-not-production';
const root = fileURLToPath(new URL('..', import.meta.url));
const tsxLoader = './apps/control-plane/node_modules/tsx/dist/loader.mjs';

/**
 * Enroll an owner phone the way the app does: mint a setup link with the admin
 * CLI against the same database, then redeem it. The token survives restarts.
 */
export async function enrollOwner(baseURL, databasePath) {
  const { stdout } = await promisify(execFile)(
    process.execPath,
    [
      '--import',
      tsxLoader,
      'apps/control-plane/src/cli.ts',
      'setup-link',
      '--server',
      baseURL,
      '--qr',
      'none',
    ],
    {
      cwd: root,
      env: { ...process.env, DATABASE_PATH: databasePath, SERVER_SECRET: scoringTestSecret },
    },
  );
  const link = stdout.split('\n').find((line) => line.startsWith('scorebug://connect?'));
  const code = link && new URL(link).searchParams.get('code');
  if (!code) throw new Error('setup-link printed no link');
  const response = await fetch(`${baseURL}/v1/setup/redeem`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ code, deviceId: randomUUID(), deviceName: 'Test owner' }),
    signal: AbortSignal.timeout(5000),
  });
  if (!response.ok) throw new Error(`setup redeem failed: HTTP ${response.status}`);
  return (await response.json()).token;
}

/** Starts a real API on an OS-selected loopback port; owns only this child. */
export async function startScoringTestServer(databasePath, environment = {}, { logPath } = {}) {
  const child = spawn(
    process.execPath,
    ['--import', tsxLoader, 'apps/control-plane/src/index.ts'],
    {
      cwd: root,
      env: {
        ...process.env,
        PORT: '0',
        HOST: '127.0.0.1',
        DATABASE_PATH: databasePath,
        SERVER_SECRET: scoringTestSecret,
        HOME_TOKEN: 'qa-home-token-not-production',
        LOG_LEVEL: 'info',
        // Ordinary scoring tests must never reconcile an ambient real relay.
        RELAY_API_URL: undefined,
        RELAY_API_USERNAME: undefined,
        RELAY_API_PASSWORD: undefined,
        SRT_PUBLISH_PEER_LATENCY_MS: undefined,
        SRT_PUBLISH_PACING: undefined,
        INGEST_PUBLISH_HOST: undefined,
        INGEST_PUBLISH_PORT: undefined,
        ...environment,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    },
  );
  const diagnosticLog = logPath
    ? createWriteStream(logPath, { flags: 'wx', mode: 0o600 })
    : undefined;
  if (diagnosticLog) {
    child.stdout.pipe(diagnosticLog, { end: false });
    child.stderr.pipe(diagnosticLog, { end: false });
  }
  const exited = new Promise((resolve) => child.once('close', resolve));
  async function stop() {
    child.kill('SIGKILL');
    await exited;
    if (diagnosticLog && !diagnosticLog.writableEnded) {
      await new Promise((resolve, reject) => {
        diagnosticLog.once('error', reject);
        diagnosticLog.end(resolve);
      });
    }
  }
  try {
    const baseURL = await new Promise((resolve, reject) => {
      let output = '';
      let errors = '';
      const timer = setTimeout(() => reject(new Error('API readiness timed out')), 20_000);
      child.once('error', (error) => {
        clearTimeout(timer);
        reject(error);
      });
      child.once('exit', (code) => {
        clearTimeout(timer);
        reject(new Error(`API exited (${code}): ${errors.slice(-1000)}`));
      });
      child.stderr.on('data', (chunk) => {
        errors = (errors + chunk).slice(-4000);
      });
      child.stdout.on('data', (chunk) => {
        output += chunk;
        const lines = output.split('\n');
        output = lines.pop() ?? '';
        for (const line of lines) {
          try {
            const item = JSON.parse(line);
            if (item.msg === 'control_plane_listening') {
              clearTimeout(timer);
              resolve(`http://127.0.0.1:${item.port}`);
            }
          } catch {
            /* unrelated diagnostic */
          }
        }
      });
    });
    return { baseURL, stop };
  } catch (error) {
    await stop();
    throw error;
  }
}
