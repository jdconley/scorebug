import { spawn, type ChildProcess } from 'node:child_process';
import type { Logger } from './logger.js';

export type PipelineSpec = {
  gameId: string;
  pullUrl: string;
  /** Full RTMPS URL **with** the stream key appended (`${RTMP_TARGET}/${streamKey}`). */
  publishUrl: string;
  scoreFile: string;
  nvenc: boolean;
  ffmpegPath?: string;
  fontPath?: string;
};

export type PipelineHandle = {
  spec: PipelineSpec;
  stop: () => void;
  waitExit: () => Promise<{ code: number | null; signal: NodeJS.Signals | null }>;
};

function filterPath(value: string): string {
  // First escape the option value, then the enclosing filter graph. No shell is used.
  return value.replace(/[\\':]/g, '\\$&').replace(/[\\'\[\],;]/g, '\\$&');
}

/**
 * Build the ffmpeg argv for a single game. `drawtext` reads `scoreFile` on
 * every frame thanks to `reload=1`; the daemon updates that file atomically.
 */
export function buildFfmpegArgs(spec: PipelineSpec): string[] {
  const drawtext = [
    `drawtext=textfile=${filterPath(spec.scoreFile)}`,
    'reload=1',
    'fontcolor=white',
    'fontsize=42',
    'box=1',
    'boxcolor=black@0.55',
    'boxborderw=18',
    'x=40',
    'y=h-100',
    `fontfile=${filterPath(spec.fontPath ?? '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf')}`,
  ].join(':');

  const video = spec.nvenc
    ? ['-c:v', 'h264_nvenc', '-preset', 'p4', '-tune', 'll', '-b:v', '6000k', '-g', '60']
    : [
        '-c:v',
        'libx264',
        '-preset',
        'veryfast',
        '-tune',
        'zerolatency',
        '-b:v',
        '6000k',
        '-g',
        '60',
      ];

  return [
    '-hide_banner',
    '-nostats',
    '-progress',
    'pipe:1',
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

/** FFmpeg output counters; these do not prove fresh frames reached the destination. */
export type PipelineProgress = Readonly<{ frame: number; outTimeUs: number }>;

export type PipelineOptions = {
  /** Called only for complete, non-regressing records with at least one changed counter. */
  onProgress?: (progress: PipelineProgress) => void;
  /** Grace period before SIGKILL, in milliseconds (0–60000). Defaults to 5000. */
  stopTimeoutMs?: number;
};

/** Retain at most one bounded line and two counters, regardless of encoder output. */
function progressReader(accept: (progress: PipelineProgress) => void): (chunk: Buffer) => void {
  let pending = '';
  let droppingLine = false;
  let invalid = false;
  let frame: number | undefined;
  let outTimeUs: number | undefined;
  let previous: PipelineProgress | undefined;

  const line = (value: string) => {
    const match = /^([a-zA-Z0-9_]+)=(.*)$/.exec(value.replace(/\r$/, ''));
    if (!match) {
      invalid = true;
      return;
    }
    const [, key, raw = ''] = match;
    if (key === 'progress') {
      if (
        !invalid &&
        (raw === 'continue' || raw === 'end') &&
        frame !== undefined &&
        outTimeUs !== undefined &&
        (!previous ||
          (frame >= previous.frame &&
            outTimeUs >= previous.outTimeUs &&
            (frame > previous.frame || outTimeUs > previous.outTimeUs)))
      ) {
        previous = { frame, outTimeUs };
        accept({ ...previous });
      }
      frame = undefined;
      outTimeUs = undefined;
      invalid = false;
    } else if (key === 'frame' || key === 'out_time_us') {
      const number = Number(raw.trim());
      if (
        !/^\d+$/.test(raw.trim()) ||
        !Number.isSafeInteger(number) ||
        (key === 'frame' ? frame !== undefined : outTimeUs !== undefined)
      ) {
        invalid = true;
      } else if (key === 'frame') {
        frame = number;
      } else {
        outTimeUs = number;
      }
    }
  };

  return (chunk) => {
    for (const character of chunk.toString()) {
      if (character === '\n') {
        if (!droppingLine) line(pending);
        pending = '';
        droppingLine = false;
      } else if (!droppingLine) {
        if (pending.length < 1024) {
          pending += character;
        } else {
          pending = '';
          droppingLine = true;
          invalid = true;
        }
      }
    }
  };
}

export function startPipeline(
  spec: PipelineSpec,
  log: Logger,
  options: PipelineOptions = {},
): PipelineHandle {
  const stopTimeoutMs = options.stopTimeoutMs ?? 5000;
  if (!Number.isInteger(stopTimeoutMs) || stopTimeoutMs < 0 || stopTimeoutMs > 60_000) {
    throw new RangeError('stopTimeoutMs must be an integer from 0 to 60000');
  }
  const args = buildFfmpegArgs(spec);
  let child: ChildProcess | undefined;
  let settled = false;
  let stopping = false;
  let killTimer: ReturnType<typeof setTimeout> | undefined;
  let settle!: (code: number | null, signal: NodeJS.Signals | null) => void;
  const exit = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>((resolve) => {
    settle = (code, signal) => {
      if (settled) return;
      settled = true;
      clearTimeout(killTimer);
      log.info('ffmpeg_exited', { gameId: spec.gameId, code, signal });
      resolve({ code, signal });
    };
  });

  log.info('ffmpeg_spawning', { gameId: spec.gameId, nvenc: spec.nvenc });
  try {
    child = spawn(spec.ffmpegPath ?? 'ffmpeg', args, { stdio: ['ignore', 'pipe', 'pipe'] });
    // Drain diagnostics without retaining them: FFmpeg echoes credentialed URLs.
    if (options.onProgress) {
      child.stdout?.on(
        'data',
        progressReader((progress) => {
          try {
            options.onProgress?.(progress);
          } catch {
            log.warn('ffmpeg_progress_callback_failed', { gameId: spec.gameId });
          }
        }),
      );
    } else {
      child.stdout?.resume();
    }
    child.stderr?.resume();
    child.on('error', () => {
      // Neither the error object nor its message is safe to log (both can contain argv).
      log.error('ffmpeg_process_error', { gameId: spec.gameId });
      if (!child?.pid) settle(null, null);
    });
    child.once('exit', settle);
  } catch {
    log.error('ffmpeg_spawn_failed', { gameId: spec.gameId });
    settle(null, null);
  }

  const alive = () => !settled && child?.exitCode === null && child.signalCode === null;
  return {
    spec,
    stop: () => {
      if (stopping || !alive()) return;
      stopping = true;
      log.info('ffmpeg_sigterm', { gameId: spec.gameId });
      child?.kill('SIGTERM');
      killTimer = setTimeout(() => {
        if (!alive()) return;
        log.info('ffmpeg_sigkill', { gameId: spec.gameId });
        child?.kill('SIGKILL');
      }, stopTimeoutMs);
    },
    waitExit: () => exit,
  };
}
