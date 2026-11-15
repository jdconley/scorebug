// Docker Desktop adapter for the existing Mac lab, not a remote deployment manager.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { command } from './media-tools.mjs';

export function validateWorkerImage(image) {
  assert(
    typeof image === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9._/:@-]*$/.test(image),
    'Supply an existing Docker worker image reference',
  );
  return image;
}
export function containerLabEnvironment(environment) {
  assert.equal(environment.ENCODER, 'software', 'The local container lane uses the CPU encoder');
  const reachable = (value) => {
    const url = new URL(value);
    if (url.hostname === '127.0.0.1' || url.hostname === 'localhost')
      url.hostname = 'host.docker.internal';
    return url.toString();
  };
  return {
    ...environment,
    CONTROL_PLANE_URL: reachable(environment.CONTROL_PLANE_URL),
    OUTPUT_URL: reachable(environment.OUTPUT_URL),
    SCORE_DIR: '/scorebug/state',
    OUTPUT_RECORDING_DIR: '/scorebug/recordings',
    FFMPEG_PATH: '/usr/bin/ffmpeg',
    FFPROBE_PATH: '/usr/bin/ffprobe',
    FONT_PATH: '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',
  };
}
export async function startContainerLabWorker(
  image,
  environment,
  artifact,
  logName = 'worker.log',
) {
  assert.equal(process.platform, 'darwin', 'This adapter requires the Mac Docker Desktop lab');
  validateWorkerImage(image);
  const env = containerLabEnvironment(environment);
  const name = `scorebug-lab-worker-${randomUUID()}`;
  const envPath = join(artifact, `${name}.env`);
  for (const path of [environment.SCORE_DIR, environment.OUTPUT_RECORDING_DIR]) {
    assert(!path.includes(':'), 'Unsupported bind path');
    await mkdir(path, { recursive: true, mode: 0o700 });
  }
  const lines = Object.entries(env).map(([key, value]) => {
    assert(
      typeof value === 'string' && !/[\r\n\0]/.test(value),
      'Invalid container environment value',
    );
    return `${key}=${value}`;
  });
  await writeFile(envPath, lines.join('\n') + '\n', { flag: 'wx', mode: 0o600 });
  async function docker(args) {
    const result = await command('docker', args, 30000);
    assert(result.ok, 'Owned container operation failed; inspect the private worker log');
    return result.stdout.trim();
  }
  // Do not pull mutable/unknown images while starting a test session.
  await docker(['image', 'inspect', image]);
  let created = false;
  try {
    await docker([
      'create',
      '--pull=never',
      '--name',
      name,
      '--env-file',
      envPath,
      '-v',
      `${environment.SCORE_DIR}:/scorebug/state`,
      '-v',
      `${environment.OUTPUT_RECORDING_DIR}:/scorebug/recordings`,
      image,
    ]);
    created = true;
    const output = createWriteStream(join(artifact, logName), { flags: 'wx', mode: 0o600 });
    const child = spawn('docker', ['start', '--attach', name], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const closed = new Promise((resolve) =>
      child.once('close', (code, signal) => resolve({ code, signal })),
    );
    const ready = new Promise((resolve, reject) => {
      let partial = '';
      child.once('error', reject);
      child.once('close', () => reject(new Error('Container exited before readiness')));
      output.once('error', reject);
      child.stdout.on('data', (chunk) => {
        partial += chunk.toString();
        const lines = partial.split('\n');
        partial = lines.pop() ?? '';
        if (partial.length > 65536) {
          reject(new Error('Oversized container log line'));
          partial = '';
        }
        for (const line of lines) {
          let event;
          try {
            event = JSON.parse(line);
          } catch {
            continue;
          }
          if (event.msg === 'worker_processing_capability') {
            if (event.available !== true)
              reject(new Error('Container encoder timing is unavailable'));
            else resolve();
          }
        }
      });
    });
    ready.catch(() => {});
    child.stdout.pipe(output, { end: false });
    child.stderr.pipe(output, { end: false });
    let stopping;
    return {
      ready,
      closed,
      stop() {
        return (stopping ??= (async () => {
          try {
            await docker(['stop', '-t', '10', name]);
            const result = await closed;
            const state = JSON.parse(
              await docker(['inspect', '--format', '{{json .State}}', name]),
            );
            assert.equal(state.Running, false);
            const exit = {
              code: state.ExitCode,
              signal: result.signal,
              forced: state.ExitCode === 137,
            };
            await writeFile(join(artifact, `${name}-exit.json`), JSON.stringify(exit), {
              mode: 0o600,
            });
            return exit;
          } finally {
            await docker(['rm', '-f', name]);
            await closed;
            await new Promise((resolve) => output.end(resolve));
          }
        })());
      },
    };
  } catch (error) {
    if (created) await docker(['rm', '-f', name]);
    throw error;
  }
}
