import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { promisify } from 'node:util';
import { setTimeout as delay } from 'node:timers/promises';
import { cancellation } from './cancellation.mjs';

const exec = promisify(execFile);
const name = `scorebug-qa-api-${randomUUID()}`;
const imageIndex = process.argv.indexOf('--image');
const suppliedImage = imageIndex >= 0 ? process.argv[imageIndex + 1] : undefined;
if (imageIndex >= 0 && !suppliedImage) throw new Error('--image requires an image name');
const image = suppliedImage ?? name;
const docker = (...args) => exec('docker', args, { timeout: 120_000, maxBuffer: 8 * 1024 * 1024 });
const checkCancellation = cancellation();
const checkedDocker = async (...args) => {
  checkCancellation();
  const result = await docker(...args);
  checkCancellation();
  return result;
};
let runAttempted = false;
try {
  if (!suppliedImage) {
    console.log('Building the final control-plane image…');
    await checkedDocker('build', '-f', 'apps/control-plane/Dockerfile', '-t', image, '.');
  }
  runAttempted = true;
  await checkedDocker(
    'run',
    '-d',
    '--name',
    name,
    '-p',
    '127.0.0.1::8787',
    '-e',
    'PHONE_TOKEN=qa-phone-token-not-production',
    '-e',
    'HOME_TOKEN=qa-home-token-not-production',
    image,
  );
  const { stdout } = await checkedDocker(
    'inspect',
    '--format',
    '{{(index (index .NetworkSettings.Ports "8787/tcp") 0).HostPort}}',
    name,
  );
  const base = `http://127.0.0.1:${Number(stdout.trim())}`;
  const deadline = Date.now() + 20_000;
  let ready = false;
  while (Date.now() < deadline) {
    const state = await checkedDocker('inspect', '--format', '{{.State.Running}}', name);
    if (state.stdout.trim() !== 'true') throw new Error('Container exited before HTTP readiness');
    try {
      const res = await fetch(`${base}/healthz`, { signal: AbortSignal.timeout(1000) });
      const body = await res.json();
      if (res.ok && body.ok === true) {
        ready = true;
        break;
      }
    } catch {
      /* process may still be starting */
    }
    await delay(250);
  }
  if (!ready) throw new Error('Container did not become healthy within 20 seconds');
  const protectedResponse = await fetch(`${base}/v1/matches/active`, {
    signal: AbortSignal.timeout(2000),
  });
  if (protectedResponse.status !== 401) throw new Error('Match API did not require authentication');
  checkCancellation();
} catch (error) {
  if (runAttempted) {
    const logs = await docker('logs', name).catch(() => ({ stdout: '', stderr: '' }));
    console.error(logs.stdout + logs.stderr);
  }
  console.error(error.message);
  process.exitCode = 1;
} finally {
  if (runAttempted)
    await docker('rm', '-f', name).catch((error) => {
      if (!/No such container/i.test(error.stderr ?? '')) {
        console.error(`Cleanup failed for ${name}: ${error.message}`);
        process.exitCode = 1;
      }
    });
  if (!suppliedImage)
    await docker('image', 'rm', image).catch((error) => {
      if (!/No such image/i.test(error.stderr ?? '')) {
        console.error(`Image cleanup failed for ${image}: ${error.message}`);
        process.exitCode = 1;
      }
    });
}
if (!process.exitCode)
  console.log(
    'PASS: final image serves health and rejects unauthenticated game access; owned resources removed.',
  );
