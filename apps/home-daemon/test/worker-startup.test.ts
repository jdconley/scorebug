import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { expect, it } from 'vitest';

async function startup(
  body: string,
  mode: 'auto' | 'off',
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
        WORKER_ID: 'mac',
        OUTPUT_ID: 'local',
        OUTPUT_URL: 'rtmp://127.0.0.1:9/live/local',
        ENCODER: 'software',
        WORKER_PROCESSING: mode,
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
it('shutdown cancels and joins startup probing before any control/report request', async () => {
  await startup("process.on('SIGTERM',()=>{});setInterval(()=>{},100);", 'auto', async (f) => {
    await expect
      .poll(() => readFile(f.binary + '.pid', 'utf8'), { timeout: 3000 })
      .toMatch(/^\d+$/);
    const pid = Number(await readFile(f.binary + '.pid', 'utf8'));
    const stoppingAt = performance.now();
    f.stop();
    expect(await f.exit).toEqual({ code: 0, signal: null });
    expect(performance.now() - stoppingAt).toBeLessThan(1500);
    expect(() => process.kill(pid, 0)).toThrow();
    expect(f.requests()).toBe(0);
    expect(f.output()).not.toContain('worker_processing_capability');
  });
});
it('unsupported statistics still start normal control/report loops', async () => {
  await startup("process.stdout.write('old help without statistics');", 'auto', async (f) => {
    await expect.poll(f.output, { timeout: 3000 }).toContain('"reason":"unsupported"');
    await expect.poll(f.requests).toBeGreaterThan(0);
    f.stop();
    expect(await f.exit).toEqual({ code: 0, signal: null });
  });
});
it('off mode skips the configured probe entirely', async () => {
  await startup('setInterval(()=>{},100);', 'off', async (f) => {
    await expect.poll(f.output, { timeout: 3000 }).toContain('worker_processing_disabled');
    await expect.poll(f.requests).toBeGreaterThan(0);
    await expect(readFile(f.binary + '.pid', 'utf8')).rejects.toThrow();
    f.stop();
    expect(await f.exit).toEqual({ code: 0, signal: null });
  });
});
it('available options enable processing diagnostics before normal polling begins', async () => {
  const help = ['pre', 'post', 'pre_fmt', 'post_fmt']
    .map((key) => `-stats_enc_${key}[:<stream_spec>] value`)
    .join('\n');
  await startup(`process.stdout.write(${JSON.stringify(help)});`, 'auto', async (f) => {
    await expect
      .poll(f.output, { timeout: 3000 })
      .toContain('"available":true,"reason":"supported"');
    await expect.poll(f.requests).toBeGreaterThan(0);
    f.stop();
    expect(await f.exit).toEqual({ code: 0, signal: null });
  });
});
