import { spawn, type ChildProcess } from 'node:child_process';
import type { Logger } from './logger.js';

export type PipelineSpec = {
  gameId: string;
  pullUrl: string;
  /** Full RTMPS URL **with** the stream key appended (`${RTMP_TARGET}/${streamKey}`). */
  publishUrl: string;
  scoreFile: string;
  nvenc: boolean;
};

export type PipelineHandle = {
  spec: PipelineSpec;
  stop: () => void;
  waitExit: () => Promise<{ code: number | null; signal: NodeJS.Signals | null }>;
};

/**
 * Build the ffmpeg argv for a single game. `drawtext` reads `scoreFile` on
 * every frame thanks to `reload=1`; the daemon updates that file atomically.
 */
export function buildFfmpegArgs(spec: PipelineSpec): string[] {
  const drawtext = [
    `drawtext=textfile=${spec.scoreFile}`,
    'reload=1',
    'fontcolor=white',
    'fontsize=42',
    'box=1',
    'boxcolor=black@0.55',
    'boxborderw=18',
    'x=40',
    'y=h-100',
    "fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
  ].join(':');

  const video = spec.nvenc
    ? ['-c:v', 'h264_nvenc', '-preset', 'p4', '-tune', 'll', '-b:v', '6000k', '-g', '60']
    : ['-c:v', 'libx264', '-preset', 'veryfast', '-tune', 'zerolatency', '-b:v', '6000k', '-g', '60'];

  return [
    '-hide_banner',
    '-loglevel',
    'warning',
    '-fflags',
    '+genpts',
    '-i',
    spec.pullUrl,
    '-vf',
    drawtext,
    ...video,
    '-c:a',
    'aac',
    '-b:a',
    '128k',
    '-ar',
    '44100',
    '-f',
    'flv',
    spec.publishUrl,
  ];
}

export function startPipeline(spec: PipelineSpec, log: Logger): PipelineHandle {
  const args = buildFfmpegArgs(spec);
  log.info('ffmpeg_spawning', { gameId: spec.gameId, nvenc: spec.nvenc });
  const child: ChildProcess = spawn('ffmpeg', args, { stdio: ['ignore', 'pipe', 'pipe'] });

  child.stdout?.on('data', (b: Buffer) => log.debug('ffmpeg_stdout', { line: b.toString().trim() }));
  child.stderr?.on('data', (b: Buffer) => log.debug('ffmpeg_stderr', { line: b.toString().trim() }));

  const exit = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>((resolve) => {
    child.once('exit', (code, signal) => {
      log.info('ffmpeg_exited', { gameId: spec.gameId, code, signal });
      resolve({ code, signal });
    });
  });

  return {
    spec,
    stop: () => {
      if (!child.killed) {
        log.info('ffmpeg_sigterm', { gameId: spec.gameId });
        child.kill('SIGTERM');
        setTimeout(() => {
          if (!child.killed) child.kill('SIGKILL');
        }, 5000);
      }
    },
    waitExit: () => exit,
  };
}
