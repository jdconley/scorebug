import { randomUUID } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { command } from './media-tools.mjs';
import { cancellation } from './cancellation.mjs';

// Unique ownership means cleanup can never stop a manually started scorebug-qa stack.
const project = `scorebug-qa-smoke-${randomUUID()}`;
const args = ['compose', '-f', 'docker-compose.dev.yml', '-p', project];
const checkCancellation = cancellation();
const headers = {
  Authorization: `Basic ${Buffer.from('qa-admin:qa-admin-not-production').toString('base64')}`,
};
try {
  const started = await command('docker', [...args, 'up', '-d'], 120_000);
  checkCancellation();
  if (!started.ok) throw new Error(started.stderr || started.error);
  for (const [port, path] of [
    [19997, 'fixture'],
    [19998, 'live/fixture'],
  ]) {
    let ready = false;
    for (let attempt = 0; attempt < 40; attempt++) {
      checkCancellation();
      try {
        const response = await fetch(`http://127.0.0.1:${port}/v3/config/paths/list`, {
          headers,
          signal: AbortSignal.timeout(1000),
        });
        if (response.ok && (await response.json()).items.some((item) => item.name === path)) {
          ready = true;
          break;
        }
      } catch {
        /* bounded startup polling */
      }
      await delay(250);
    }
    if (!ready)
      throw new Error(`Local MediaMTX on port ${port} did not expose fixture path ${path}`);
    const denied = await fetch(`http://127.0.0.1:${port}/v3/config/paths/list`, {
      signal: AbortSignal.timeout(2000),
    });
    if (denied.status !== 401)
      throw new Error(`Management API on ${port} allowed anonymous access`);
  }
  checkCancellation();
} catch (error) {
  console.error(error.message);
  console.error((await command('docker', [...args, 'logs', '--tail', '30'])).stdout);
  process.exitCode = 1;
} finally {
  const stopped = await command('docker', [...args, 'down', '--volumes'], 30_000);
  if (!stopped.ok) {
    console.error(`Cleanup failed for ${project}: ${stopped.stderr}`);
    process.exitCode = 1;
  }
}
if (!process.exitCode) {
  console.log(
    'PASS: isolated ingest and sink start, expose fixture paths, and require management credentials; owned resources removed.',
  );
  console.log('This is infrastructure readiness; media and per-game credentials are milestone 2.');
}
