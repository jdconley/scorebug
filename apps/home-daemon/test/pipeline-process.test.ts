import { chmod, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { expect, it } from 'vitest';
import { buildFfmpegArgs, startPipeline } from '../src/pipeline.js';
import { createLogger } from '../src/logger.js';

it('executes the configured media binary instead of the one on PATH', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'scorebug-tool-'));
  try {
    const binary = join(dir, 'test-encoder');
    await writeFile(binary, '#!/bin/sh\nexit 0\n');
    await chmod(binary, 0o755);
    const pipeline = startPipeline(
      {
        gameId: 'qa',
        pullUrl: 'unused',
        publishUrl: 'unused',
        scoreFile: join(dir, 'score.txt'),
        nvenc: false,
        ffmpegPath: binary,
      },
      createLogger('error'),
    );
    expect(await pipeline.waitExit()).toEqual({ code: 0, signal: null });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

it('uses the selected font for the overlay', () => {
  const args = buildFfmpegArgs({
    gameId: 'qa',
    pullUrl: 'unused',
    publishUrl: 'unused',
    scoreFile: '/tmp/score.txt',
    nvenc: false,
    fontPath: '/custom/score.ttf',
  });
  expect(args[args.indexOf('-vf') + 1]).toContain('/custom/score.ttf');
  expect(args[args.indexOf('-vf') + 1]).not.toContain('/usr/share/fonts');
});
