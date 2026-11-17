import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { expect, it } from 'vitest';

async function startup(
  body: string,
  check: (f: {
    binary: string;
    output: () => string;
    requests: () => number;
    stop: () => void;
    exit: Promise<{ code: number | null; signal: NodeJS.Signals | null }>;
  }) => Promise<void>,
) {
  const dir = await mkdtemp(join(tmpdir(), 'scorebug-startup-'));
  const binary = join(dir, 'ffmpeg');
  await writeFile(
    binary,
    `#!${process.execPath}\nrequire('node:fs').writeFileSync(__filename+'.pid',String(process.pid));\n${body}\n`,
  );
  await chmod(binary, 0o755);
  let requests = 0;
  const server = createServer((_req, res) => {
    requests++;
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ assignment: null }));
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = (server.address() as { port: number }).port;
  const child = spawn(
    process.execPath,
    [
      '--import',
      import.meta.resolve('tsx'),
      fileURLToPath(new URL('../src/index.ts', import.meta.url)),
    ],
    {
      env: {
        ...process.env,
        CONTROL_PLANE_URL: `http://127.0.0.1:${port}`,
        HOME_TOKEN: 'local-startup-test-token',
        WORKER_ID: 'match',
        OUTPUT_ID: 'youtube',
        FFMPEG_PATH: binary,
        SCORE_DIR: dir,
        LOG_LEVEL: 'info',
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    },
  );
  let output = '';
  child.stdout.on('data', (b) => {
    output = (output + b.toString()).slice(-32768);
  });
  child.stderr.on('data', (b) => {
    output = (output + b.toString()).slice(-32768);
  });
  const exit = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>(
    (resolve, reject) => {
      child.once('error', reject);
      child.once('close', (code, signal) => resolve({ code, signal }));
    },
  );
  try {
    await check({
      binary,
      output: () => output,
      requests: () => requests,
      stop: () => child.kill('SIGTERM'),
      exit,
    });
  } finally {
    child.kill('SIGKILL');
    await exit;
    try {
      process.kill(-Number(await readFile(binary + '.pid', 'utf8')), 'SIGKILL');
    } catch {
      /* Owned group already gone or probe skipped. */
    }
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await rm(dir, { recursive: true, force: true });
  }
}
it('polls control immediately at startup and exits cleanly on SIGTERM', async () => {
  await startup('process.exit(1);', async (f) => {
    await expect.poll(f.output, { timeout: 3000 }).toContain('worker_started');
    await expect.poll(f.requests, { timeout: 3000 }).toBeGreaterThan(0);
    const stoppingAt = performance.now();
    f.stop();
    expect(await f.exit).toEqual({ code: 0, signal: null });
    expect(performance.now() - stoppingAt).toBeLessThan(1500);
  });
});
