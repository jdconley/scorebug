import type { EncoderDiagnosticSnapshot } from './encoder-diagnostics.mjs';
import type { WorkerProcessingReport } from '@scorebug/protocol';
import { DecodedFrameHistory, type DecodedFrameHistorySnapshot } from './decoded-frame-history.js';
import { observeDecodedPipe } from './decoded-pipe.js';
import type { WorkerProcessingSnapshot } from './worker-processing.js';
import {
  WorkerProcessingWindows,
  type WorkerProcessingWindow,
} from './worker-processing-windows.js';
import { DECODED_VIDEO_TRANSPORT_CLOCK } from '@scorebug/protocol';
import {
  EncoderTimingTelemetry,
  observeEncoderTimingPipe,
  type EncoderTimingSnapshot,
} from './encoder-timing.js';
import { fork, type ChildProcess } from 'node:child_process';
import type { Readable } from 'node:stream';
import type { Logger } from './logger.js';
import {
  DecodedVideoLifetime,
  DecodedVideoTelemetry,
  type DecodedVideoLifetimeSnapshot,
  type DecodedVideoSnapshot,
} from './decoded-video.js';

export type PipelineSpec = {
  gameId: string;
  pullUrl: string;
  /** Full RTMPS URL **with** the stream key appended (`${RTMP_TARGET}/${streamKey}`). */
  publishUrl: string;
  scoreFile: string;
  nvenc: boolean;
  encoder?: 'software' | 'videotoolbox' | 'nvenc';
  profile?: { width: number; height: number; fps: number; bitrateKbps: number };
  ffmpegPath?: string;
  fontPath?: string;
};

export type PipelineHandle = {
  spec: PipelineSpec;
  stop: () => void;
  waitExit: () => Promise<{ code: number | null; signal: NodeJS.Signals | null }>;
  /** Decoder ingress only; PTS ticks use 1/90000. Fresh pipeline means fresh scope. */
  snapshotDecodedVideo?: () => DecodedVideoSnapshot;
  snapshotEncoderTiming?: () => EncoderTimingSnapshot | null;
  snapshotProcessing?: () => WorkerProcessingSnapshot | null;
  snapshotProcessingWindow?: () => WorkerProcessingWindow | null;
  snapshotVideoEvidence?: () => {
    decodedVideo: DecodedVideoSnapshot;
    processing?: WorkerProcessingReport;
  };
};

function filterPath(value: string): string {
  // First escape the option value, then the enclosing filter graph. No shell is used.
  return value.replace(/[\\':]/g, '\\$&').replace(/[\\'\[\],;]/g, '\\$&');
}

/**
 * Build the ffmpeg argv for a single game. `drawtext` reads `scoreFile` on
 * every frame thanks to `reload=1`; the daemon updates that file atomically.
 */
export function buildFfmpegArgs(
  spec: PipelineSpec,
  options: { encoderTiming?: boolean } = {},
): string[] {
  const profile = spec.profile;
  if (
    profile &&
    (!Number.isInteger(profile.width) ||
      profile.width < 2 ||
      profile.width > 7680 ||
      profile.width % 2 ||
      !Number.isInteger(profile.height) ||
      profile.height < 2 ||
      profile.height > 4320 ||
      profile.height % 2 ||
      !Number.isInteger(profile.fps) ||
      profile.fps < 1 ||
      profile.fps > 60 ||
      !Number.isInteger(profile.bitrateKbps) ||
      profile.bitrateKbps < 100 ||
      profile.bitrateKbps > 100000)
  )
    throw new Error('invalid_video_profile');
  const ratio = (profile?.height ?? 1080) / 1080;
  const drawtext = [
    `drawtext=textfile=${filterPath(spec.scoreFile)}`,
    'reload=1',
    'expansion=none',
    'fontcolor=white',
    `fontsize=${Math.max(14, Math.round(42 * ratio))}`,
    'box=1',
    'boxcolor=black@0.55',
    `boxborderw=${Math.round(18 * ratio)}`,
    `x=${Math.round(40 * ratio)}`,
    `y=h-${Math.round(100 * ratio)}`,
    `fontfile=${filterPath(spec.fontPath ?? '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf')}`,
  ].join(':');

  const encoder = spec.encoder ?? (spec.nvenc ? 'nvenc' : 'software');
  const video =
    encoder === 'videotoolbox'
      ? ['-c:v', 'h264_videotoolbox', '-allow_sw', '0', '-realtime', '1', '-bf', '0']
      : encoder === 'nvenc'
        ? ['-c:v', 'h264_nvenc', '-preset', 'p4', '-tune', 'll']
        : ['-c:v', 'libx264', '-preset', 'veryfast', '-tune', 'zerolatency'];
  video.push(
    '-b:v',
    `${profile?.bitrateKbps ?? 6000}k`,
    '-g',
    String((profile?.fps ?? 30) * 2),
    '-pix_fmt',
    'yuv420p',
  );
  // Preserve acquisition gaps on the common A/V timeline. Auto/CFR can pad
  // early audio with duplicates; VFR can remove frames around timestamp wrap.
  // Passthrough leaves frame removal solely to the explicit cap below.
  // Select at most one frame per anchored cap interval, retaining source PTS.
  // Allow one input tick for floor-quantized acquisition timestamps plus half
  // a tick for input rescaling, so boundary frames keep their intended bucket.
  video.push('-fps_mode', 'passthrough', '-enc_time_base:v', '-1');
  const cap = profile
    ? `select='isnan(prev_selected_t)+gt(floor((t-start_t+1.5*TB)*${profile.fps}),floor((prev_selected_t-start_t+1.5*TB)*${profile.fps}))',`
    : '';
  const filter = profile
    ? `${cap}scale=${profile.width}:${profile.height}:force_original_aspect_ratio=decrease:force_divisible_by=2,pad=${profile.width}:${profile.height}:(ow-iw)/2:(oh-ih)/2:eval=frame,${drawtext}`
    : drawtext;
  // A sink-only side branch observes every decoder frame without changing the
  // live branch's timebase (the cap uses its rounding tolerance). The simple
  // graph still has exactly one external input and one output.
  const telemetry =
    "metadata=mode=delete:key=scorebug.source,split[decoded][live];[decoded]settb=1/90000,metadata=mode=add:key=scorebug.source:value=1,metadata=mode=print:key=scorebug.source:file='pipe\\:3':direct=1,metadata=mode=delete:key=scorebug.source,nullsink;[live]";

  // copyts preserves the decoder's transport clock; avoid_negative_ts only
  // normalizes outgoing mux timestamps onto a nonnegative timeline.
  return [
    '-hide_banner',
    '-nostats',
    '-progress',
    'pipe:1',
    '-loglevel',
    'warning',
    '-fflags',
    '+genpts',
    '-copyts',
    // The fixed scale/pad canvas absorbs input dimension changes. Keep filter
    // state so telemetry ordinals and the source-FPS cap anchor cannot reset.
    // The legacy profile-less graph has no canvas normalization guarantee.
    ...(profile ? ['-reinit_filter:v:0', '0'] : []),
    '-i',
    spec.pullUrl,
    '-map',
    '0:v:0',
    '-map',
    '0:a:0',
    '-vf',
    telemetry + filter,
    ...video,
    ...(options.encoderTiming
      ? [
          '-stats_enc_pre:v:0',
          'pipe:4',
          '-stats_enc_pre_fmt:v:0',
          'pre {n} {tb} {pts}',
          '-stats_enc_post:v:0',
          'pipe:4',
          '-stats_enc_post_fmt:v:0',
          'post {n} {tb} {pts}',
        ]
      : []),
    '-c:a',
    'aac',
    '-b:a',
    '128k',
    '-ar',
    '44100',
    '-avoid_negative_ts',
    'make_zero',
    '-f',
    'flv',
    spec.publishUrl,
  ];
}

/** FFmpeg output counters; these do not prove fresh frames reached the destination. */
export type PipelineProgress = Readonly<{ frame: number; outTimeUs: number }>;

export type PipelineTerminal = Readonly<{
  decodedVideo: DecodedVideoLifetimeSnapshot;
  telemetryEOF: boolean;
  diagnostics?: EncoderDiagnosticSnapshot;
  /** Null means the guardian never reported the encoder status. */
  encoderExit: { code: number | null; signal: NodeJS.Signals | null } | null;
  outputProgress: PipelineProgress | null;
  encoderTiming?: EncoderTimingSnapshot;
  decodedFrameHistory?: DecodedFrameHistorySnapshot;
}>;

export type PipelineOptions = {
  /** Opt-in diagnostics requiring FFmpeg stats_enc_pre/post support. Never capacity evidence. */
  encoderTiming?: boolean;
  /** Optional test diagnostics, emitted once after all guardian pipes close. */
  onTerminal?: (terminal: PipelineTerminal) => void;
  /** Monotonic milliseconds; telemetry never compares source PTS to this clock. */
  monotonicNow?: () => number;
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
  const args = buildFfmpegArgs(spec, options);
  const encoderTiming = options.encoderTiming
    ? new EncoderTimingTelemetry(options.monotonicNow)
    : undefined;
  const decodedVideo = new DecodedVideoTelemetry(options.monotonicNow);
  const decodedHistory = encoderTiming
    ? new DecodedFrameHistory(options.monotonicNow, encoderTiming.scopeID)
    : undefined;
  const processingWindows = encoderTiming ? new WorkerProcessingWindows() : undefined;
  const lifetime = options.onTerminal ? new DecodedVideoLifetime() : undefined;
  let telemetryEOF = false;
  let diagnostics: EncoderDiagnosticSnapshot | undefined;
  let outputProgress: PipelineProgress | null = null;
  let terminalEmitted = false;
  let child: ChildProcess | undefined;
  let settled = false;
  let guardianSpawnFailed = false;
  let stopping = false;
  let encoderExit: { code: number | null; signal: NodeJS.Signals | null } | undefined;
  const terminal = () => {
    if (!lifetime || terminalEmitted) return;
    terminalEmitted = true;
    lifetime.end();
    try {
      options.onTerminal?.({
        decodedVideo: lifetime.snapshot(),
        telemetryEOF,
        ...(diagnostics ? { diagnostics } : {}),
        encoderExit: encoderExit ? { ...encoderExit } : null,
        outputProgress: outputProgress ? { ...outputProgress } : null,
        ...(encoderTiming ? { encoderTiming: encoderTiming.snapshot() } : {}),
        ...(decodedHistory ? { decodedFrameHistory: decodedHistory.snapshot() } : {}),
      });
    } catch {
      // Diagnostics must never change shutdown, including a failing diagnostic logger.
      try {
        log.warn('ffmpeg_terminal_callback_failed', { gameId: spec.gameId });
      } catch {}
    }
  };
  const failedBeforeSpawn = () => {
    decodedVideo.end();
    encoderTiming?.end();
    decodedHistory?.end();
    terminal();
    settle(null, null);
  };
  let settle!: (code: number | null, signal: NodeJS.Signals | null) => void;
  const exit = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>((resolve) => {
    settle = (code, signal) => {
      if (settled) return;
      settled = true;
      log.info('ffmpeg_exited', { gameId: spec.gameId, code, signal });
      resolve({ code, signal });
    };
  });
  const send = (message: Record<string, unknown>) => {
    if (!child?.connected) return;
    try {
      child.send(message, (error) => {
        if (error) log.error('ffmpeg_guardian_connection_failed', { gameId: spec.gameId });
      });
    } catch {
      log.error('ffmpeg_guardian_connection_failed', { gameId: spec.gameId });
    }
  };

  log.info('ffmpeg_spawning', { gameId: spec.gameId, nvenc: spec.nvenc });
  try {
    child = fork(new URL('./pipeline-guardian.mjs', import.meta.url), [], {
      execArgv: [],
      stdio: ['ignore', 'pipe', 'ignore', 'ipc', 'pipe', 'pipe'],
    });
    // Guardian IPC remains fd3; fd4 becomes FFmpeg decoded telemetry fd3,
    // and fd5 becomes the independent encoder timing fd4. Always drain both.
    const timingPipe = child.stdio.at(5) as Readable;
    observeEncoderTimingPipe(timingPipe, encoderTiming);
    // Guardian IPC remains fd3; its fd4 becomes FFmpeg's telemetry fd3.
    // Always drain, including after invalid evidence and without an observer.
    const telemetry = child.stdio[4] as Readable;
    observeDecodedPipe(
      telemetry,
      [decodedVideo, ...(lifetime ? [lifetime] : []), ...(decodedHistory ? [decodedHistory] : [])],
      () => {
        telemetryEOF = true;
      },
    );
    // Drain diagnostics without retaining them: FFmpeg echoes credentialed URLs.
    if (options.onProgress || options.onTerminal) {
      child.stdout?.on(
        'data',
        progressReader((progress) => {
          if (lifetime) outputProgress = { ...progress };
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
    child.on('message', (message: unknown) => {
      const event = message as {
        event: string;
        code: number | null;
        signal: NodeJS.Signals | null;
        diagnostics?: EncoderDiagnosticSnapshot;
      };
      if (event.event === 'exit') {
        encoderExit = { code: event.code, signal: event.signal };
        diagnostics = event.diagnostics;
      } else if (event.event === 'sigterm' || event.event === 'sigkill') {
        log.info(`ffmpeg_${event.event}`, { gameId: spec.gameId });
      } else if (event.event === 'process_error' || event.event === 'spawn_failed') {
        log.error(`ffmpeg_${event.event}`, { gameId: spec.gameId });
      }
    });
    child.on('error', () => {
      // Neither the error object nor its message is safe to log (both can contain argv).
      log.error('ffmpeg_process_error', { gameId: spec.gameId });
      if (!child?.pid) guardianSpawnFailed = true;
    });
    child.once('close', () => {
      decodedVideo.end();
      encoderTiming?.end();
      decodedHistory?.end();
      terminal();
      // Drain progress before resolving. Guardian death alone does not prove the
      // encoder exited: fail closed so the supervisor cannot overlap publishers.
      if (encoderExit) settle(encoderExit.code, encoderExit.signal);
      else if (guardianSpawnFailed) settle(null, null);
      else if (!settled) log.error('ffmpeg_guardian_lost', { gameId: spec.gameId });
    });
    send({
      type: 'start',
      binary: spec.ffmpegPath ?? 'ffmpeg',
      args,
      stopTimeoutMs,
      diagnostics: Boolean(options.onTerminal),
    });
  } catch {
    log.error('ffmpeg_spawn_failed', { gameId: spec.gameId });
    if (!child?.pid) failedBeforeSpawn();
  }

  const sampleVideoEvidence = () => {
    const video = { ...decodedVideo.snapshot(), clock: DECODED_VIDEO_TRANSPORT_CLOCK };
    const processing =
      processingWindows && decodedHistory && encoderTiming
        ? processingWindows.observe(video, {
            decoded: decodedHistory.snapshot(),
            encoded: encoderTiming.snapshot(),
          })
        : null;
    return {
      decodedVideo: video,
      ...(processing
        ? {
            processing: {
              ...processing,
              encoder: spec.encoder ?? (spec.nvenc ? ('nvenc' as const) : ('software' as const)),
            },
          }
        : {}),
    };
  };
  const alive = () => !settled && child?.exitCode === null && child.signalCode === null;
  return {
    spec,
    stop: () => {
      if (stopping || !alive()) return;
      stopping = true;
      send({ type: 'stop' });
    },
    waitExit: () => exit,
    snapshotEncoderTiming: () => encoderTiming?.snapshot() ?? null,
    snapshotProcessing: () =>
      decodedHistory && encoderTiming
        ? { decoded: decodedHistory.snapshot(), encoded: encoderTiming.snapshot() }
        : null,
    snapshotVideoEvidence: sampleVideoEvidence,
    snapshotProcessingWindow: () => sampleVideoEvidence().processing ?? null,
    snapshotDecodedVideo: () => ({
      ...decodedVideo.snapshot(),
      clock: DECODED_VIDEO_TRANSPORT_CLOCK,
    }),
  };
}
