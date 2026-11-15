import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { expect, it } from 'vitest';
import { probeEncoderStatistics } from '../src/encoder-statistics-capability.js';
const help = ['pre', 'post', 'pre_fmt', 'post_fmt']
  .map((key) => `-stats_enc_${key}[:<stream_spec>] <value> description`)
  .join('\n');
async function fixture(body: string, run: (binary: string, dir: string) => Promise<void>) {
  const dir = await mkdtemp(join(tmpdir(), 'scorebug-capability-'));
  const binary = join(dir, 'ffmpeg');
  await writeFile(binary, `#!${process.execPath}\n${body}\n`);
  await chmod(binary, 0o755);
  try {
    await run(binary, dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}
it('requires all exact production option names and executes only a help query', async () => {
  await fixture(
    `require('node:fs').writeFileSync(__filename+'.args',JSON.stringify(process.argv.slice(2)));process.stdout.write(${JSON.stringify(help)});`,
    async (binary) => {
      expect(await probeEncoderStatistics(binary)).toEqual({
        available: true,
        reason: 'supported',
      });
      expect(JSON.parse(await readFile(binary + '.args', 'utf8'))).toEqual([
        '-hide_banner',
        '-h',
        'full',
      ]);
    },
  );
});
it.each(['-stats_enc_post_fmt', '-stats_enc_pre_fmt', '-stats_enc_post', '-stats_enc_pre'])(
  'rejects missing %s and lookalike/prose mentions',
  async (missing) => {
    const text =
      help
        .split('\n')
        .filter((line) => !line.startsWith(missing + '['))
        .join('\n') +
      '\n' +
      missing +
      '_other <value>\nusage mentions ' +
      missing;
    await fixture(`process.stderr.write(${JSON.stringify(text)});`, async (binary) => {
      expect(await probeEncoderStatistics(binary)).toEqual({
        available: false,
        reason: 'unsupported',
      });
    });
  },
);
it('does not expose failed command diagnostics or treat flags from a failed help query as support', async () => {
  await fixture(
    `process.stdout.write(${JSON.stringify(help)});process.stderr.write('SECRET');process.exitCode=1;`,
    async (binary) => {
      expect(await probeEncoderStatistics(binary)).toEqual({ available: false, reason: 'exit' });
    },
  );
  expect(await probeEncoderStatistics('/missing/PRIVATE/ffmpeg')).toEqual({
    available: false,
    reason: 'spawn',
  });
  expect(await probeEncoderStatistics('invalid\0binary')).toEqual({
    available: false,
    reason: 'spawn',
  });
});
it('kills and joins a timed out child even if TERM is ignored', async () => {
  await fixture(
    `process.on('SIGTERM',()=>{});require('node:fs').writeFileSync(__filename+'.pid',String(process.pid));setInterval(()=>{},100);`,
    async (binary) => {
      expect(await probeEncoderStatistics(binary, { timeoutMs: 1500 })).toEqual({
        available: false,
        reason: 'timeout',
      });
      const pid = Number(await readFile(binary + '.pid', 'utf8'));
      expect(() => process.kill(pid, 0)).toThrow();
    },
  );
});
it('limits total help output and joins the child', async () => {
  await fixture(
    `process.stdout.write('x'.repeat(5*1024*1024));setInterval(()=>{},100);`,
    async (binary) => {
      expect(await probeEncoderStatistics(binary)).toEqual({
        available: false,
        reason: 'output_limit',
      });
    },
  );
});
it('cancels an active probe and refuses a pre-cancelled one', async () => {
  const controller = new AbortController();
  await fixture(
    `require('node:fs').writeFileSync(__filename+'.pid',String(process.pid));setInterval(()=>{},100);`,
    async (binary) => {
      const pending = probeEncoderStatistics(binary, { signal: controller.signal });
      await expect.poll(() => readFile(binary + '.pid', 'utf8')).toMatch(/^\d+$/);
      const pid = Number(await readFile(binary + '.pid', 'utf8'));
      controller.abort();
      expect(await pending).toEqual({ available: false, reason: 'cancelled' });
      expect(() => process.kill(pid, 0)).toThrow();
      expect(await probeEncoderStatistics('/missing', { signal: controller.signal })).toEqual({
        available: false,
        reason: 'cancelled',
      });
    },
  );
});

it('bounds and cleans up a wrapper descendant that retains the output pipes', async () => {
  await fixture(
    `const child=require('node:child_process').spawn(process.execPath,['-e','setInterval(()=>{},100)'],{stdio:'inherit'});require('node:fs').writeFileSync(__filename+'.descendant',String(child.pid));child.unref();`,
    async (binary) => {
      const pending = probeEncoderStatistics(binary, { timeoutMs: 1500 });
      await expect.poll(() => readFile(binary + '.descendant', 'utf8')).toMatch(/^\d+$/);
      const pid = Number(await readFile(binary + '.descendant', 'utf8'));
      let timer: ReturnType<typeof setTimeout>;
      try {
        const result = await Promise.race([
          pending,
          new Promise((resolve) => {
            timer = setTimeout(() => resolve('unbounded'), 2500);
          }),
        ]);
        expect(result).toEqual({ available: false, reason: 'timeout' });
        await expect
          .poll(() => {
            try {
              process.kill(pid, 0);
              return true;
            } catch {
              return false;
            }
          })
          .toBe(false);
      } finally {
        clearTimeout(timer!);
        try {
          process.kill(pid, 'SIGKILL');
        } catch {
          /* Already reaped. */
        }
        await pending;
      }
    },
  );
});
