import { frameRateCapFilter } from './frame-rate-cap.js';
import type { DecodedGeometrySnapshot } from './decoded-geometry.mjs';
import type { DecoderDeliveryPacket } from '@scorebug/protocol';
import { DecoderDeliveryTelemetry, type DecoderDeliverySnapshot } from './decoder-delivery.js';
import { DecoderCadenceTelemetry, type DecoderCadenceSnapshot } from './decoder-cadence.js';
import type { EncoderDiagnosticSnapshot } from './encoder-diagnostics.mjs';
import type { WorkerPacketTimingSnapshot } from './worker-packet-timing.mjs';
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
import type { Readable, Writable } from 'node:stream';
import type { Logger } from './logger.js';
import { OverlayFeed } from './scorebug/feed.js';
import { overlayRegions } from './scorebug/layout.js';
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
  publishUrl?: string;
  /** Fresh per-attempt local path; recording contains the final proxy overlay. */
  recordingPath?: string;
  /** Serialized ScorebugOverlay JSON; the overlay feed re-renders when it changes. */
  scoreFile: string;
  nvenc: boolean;
  encoder?: 'software' | 'videotoolbox' | 'nvenc';
  /** Input decoder only; automatic preserves FFmpeg defaults. */
  decoderThreading?: 'automatic' | 'slice';
  profile?: { width: number; height: number; fps: number; bitrateKbps: number };
  ffmpegPath?: string;
};

export type PipelineHandle = {
  spec: PipelineSpec;
  stop: () => void;
  waitExit: () => Promise<{ code: number | null; signal: NodeJS.Signals | null }>;
  /** Decoder ingress only; PTS ticks use 1/90000. Fresh pipeline means fresh scope. */
  snapshotDecodedVideo?: () => DecodedVideoSnapshot;
  /** Short decoder-arrival windows; no source-loss or viewer-delivery claim. */
  snapshotDecoderCadence?: () => DecoderCadenceSnapshot;
  /** Optional local arrival log, separate from negotiated packet reporting. */
  snapshotDecoderDelivery?: () => DecoderDeliverySnapshot | null;
  snapshotEncoderTiming?: () => EncoderTimingSnapshot | null;
  snapshotProcessing?: () => WorkerProcessingSnapshot | null;
  snapshotProcessingWindow?: () => WorkerProcessingWindow | null;
  snapshotVideoEvidence?: () => {
    decodedVideo: DecodedVideoSnapshot;
    decoderCadence?: DecoderCadenceSnapshot;
    decoderDelivery?: DecoderDeliveryPacket;
    processing?: WorkerProcessingReport;
  };
};

/** Overlay canvas: the output canvas, or 1080p for the legacy profile-less graph. */
export function overlaySize(spec: PipelineSpec): { width: number; height: number } {
  return spec.profile
    ? { width: spec.profile.width, height: spec.profile.height }
    : { width: 1920, height: 1080 };
}

/** Shared initialization options for the live pipeline and local startup probe. */
export function videoEncoderArgs(encoder: 'software' | 'videotoolbox' | 'nvenc'): string[] {
  return encoder === 'videotoolbox'
    ? ['-c:v', 'h264_videotoolbox', '-allow_sw', '0', '-realtime', '1', '-bf', '0']
    : encoder === 'nvenc'
      ? ['-c:v', 'h264_nvenc', '-preset', 'p4', '-tune', 'll']
      : ['-c:v', 'libx264', '-preset', 'veryfast', '-tune', 'zerolatency'];
}

export function buildFfmpegArgs(
  spec: PipelineSpec,
  options: {
    encoderTiming?: boolean;
    decoderDiagnostics?: boolean;
    packetTiming?: boolean;
    decodedGeometry?: boolean;
  } = {},
): string[] {
  if (!spec.publishUrl && !spec.recordingPath) throw new Error('missing_pipeline_output');
  // delay_moov preserves unequal first A/V timestamps via edit lists. An empty
  // initial moov would reset each track separately and destroy the audio lead.
  const fragmentedMp4 = '+frag_keyframe+delay_moov+default_base_moof';
  // Tee splits slave names with av_get_token; this is FFmpeg escaping, not shell quoting.
  const teePath = (value: string) => value.replace(/[\\'|]/g, '\\$&');
  const output = spec.recordingPath
    ? spec.publishUrl
      ? [
          '-n',
          '-flags',
          '+global_header',
          '-f',
          'tee',
          `[f=flv]${teePath(spec.publishUrl)}|[f=mp4:movflags=${fragmentedMp4}]${teePath(spec.recordingPath)}`,
        ]
      : ['-n', '-movflags', fragmentedMp4, '-f', 'mp4', spec.recordingPath]
    : ['-f', 'flv', spec.publishUrl!];
  const decoderThreading = spec.decoderThreading ?? 'automatic';
  if (!['automatic', 'slice'].includes(decoderThreading))
    throw new Error('invalid_decoder_threading');
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
  const encoder = spec.encoder ?? (spec.nvenc ? 'nvenc' : 'software');
  const video = videoEncoderArgs(encoder);
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
  // A two-credit token bucket tolerates acquisition jitter with one spare frame,
  // while limiting sustained selection to the output rate. Anchored floor buckets
  // discarded ordinary 30fps frames on either side of a clock boundary. Credits
  // never grow across an outage; duplicate/regressing PTS cannot be selected or
  // mint new credits. Keep source PTS and the shared A/V timeline unchanged.
  video.push('-fps_mode', 'passthrough', '-enc_time_base:v', 'demux');
  const cap = profile ? `${frameRateCapFilter(profile.fps)},` : '';
  const canvas = profile
    ? `${cap}scale=${profile.width}:${profile.height}:force_original_aspect_ratio=decrease:force_divisible_by=2,pad=${profile.width}:${profile.height}:(ow-iw)/2:(oh-ih)/2:eval=frame`
    : 'null';
  // Input 1 is the worker's timestamped RGBA scorebug (see scorebug/feed.ts):
  // one packed box per style. Each box is cropped out, converted to YUVA and
  // blended at its place with straight alpha in the main format. Only the
  // active style's box has pixels; blending cost is the boxes' area. The RGB to
  // YUV matrix is left to format negotiation so it follows the camera's: forcing
  // BT.709 against an untagged source made FFmpeg 7.1 convert every output frame
  // through RGB (2x CPU). eof_action=pass: a lost feed drops the graphic, while
  // source EOF still ends the graph (an overlay frame never creates video).
  const layout = overlayRegions(overlaySize(spec));
  const yuva = 'format=yuva420p';
  const labels = layout.regions.map((region) => `scorebug_${region.style}`);
  const filter =
    `${canvas}[base];` +
    `[1:v:0]split=${labels.length}${labels.map((label) => `[${label}_packed]`).join('')};` +
    layout.regions
      .map(
        ({ frame, canvas: at }, index) =>
          `[${labels[index]}_packed]crop=${frame.width}:${frame.height}:${at.x}:${at.y},${yuva}[${labels[index]}];`,
      )
      .join('') +
    layout.regions
      .map(
        ({ frame }, index) =>
          `[${index ? `${labels[index - 1]}_done` : 'base'}][${labels[index]}]overlay=x=${frame.x}:y=${frame.y}:eof_action=pass:format=auto` +
          `[${index === labels.length - 1 ? 'video' : `${labels[index]}_done`}]`,
      )
      .join(';');
  // A sink-only side branch observes every decoder frame without changing the
  // live branch's timebase (the cap uses its rounding tolerance). The graph has
  // one output; input 1 (the scorebug) feeds only the final overlays.
  const geometry =
    options.decoderDiagnostics && options.decodedGeometry
      ? 'showinfo@scorebug_geometry=checksum=0:udu_sei_as_ascii=0,'
      : '';
  const telemetry =
    'metadata=mode=delete:key=scorebug.source,split[decoded][live];[decoded]settb=1/90000,' +
    geometry +
    "metadata=mode=add:key=scorebug.source:value=1,metadata=mode=print:key=scorebug.source:file='pipe\\:3':direct=1,metadata=mode=delete:key=scorebug.source,nullsink;[live]settb=1/90000,";

  // copyts preserves the decoder's transport clock; avoid_negative_ts only
  // normalizes outgoing mux timestamps onto a nonnegative timeline.
  return [
    '-hide_banner',
    '-nostats',
    '-progress',
    'pipe:1',
    '-loglevel',
    options.decoderDiagnostics || options.packetTiming ? 'repeat+level+info' : 'warning',
    ...(options.packetTiming ? ['-debug_ts'] : []),
    '-fflags',
    '+genpts',
    '-copyts',
    // The fixed scale/pad canvas absorbs input dimension changes. Keep filter
    // state so telemetry ordinals and the source-FPS cap anchor cannot reset.
    // The legacy profile-less graph has no canvas normalization guarantee.
    ...(profile ? ['-reinit_filter:v:0', '0'] : []),
    // Input-scoped: never changes the selected output encoder's threading.
    ...(decoderThreading === 'slice' ? ['-thread_type:v:0', 'slice'] : []),
    '-i',
    spec.pullUrl,
    // Bounded overlay prefetch: the feed writes at most ~2 frames ahead of main.
    '-thread_queue_size',
    '8',
    '-f',
    'matroska',
    '-i',
    'pipe:0',
    '-filter_complex',
    '[0:v:0]' + telemetry + filter,
    '-map',
    '[video]',
    '-map',
    '0:a:0',
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
    ...output,
  ];
}

/** FFmpeg output counters; these do not prove fresh frames reached the destination. */
export type PipelineProgress = Readonly<{ frame: number; outTimeUs: number }>;

export type PipelineTerminal = Readonly<{
  decodedVideo: DecodedVideoLifetimeSnapshot;
  telemetryEOF: boolean;
  diagnostics?: EncoderDiagnosticSnapshot;
  packetTiming?: WorkerPacketTimingSnapshot;
  decodedGeometry?: DecodedGeometrySnapshot;
  /** Null means the guardian never reported the encoder status. */
  encoderExit: { code: number | null; signal: NodeJS.Signals | null } | null;
  outputProgress: PipelineProgress | null;
  encoderTiming?: EncoderTimingSnapshot;
  decodedFrameHistory?: DecodedFrameHistorySnapshot;
  decoderCadence?: DecoderCadenceSnapshot;
}>;

export type PipelineOptions = {
  /** Test-only numeric packet prefixes; requires onTerminal, never health evidence. */
  packetTiming?: boolean;
  /** Test-only pre-scale decoded dimensions; requires onTerminal. */
  decodedGeometry?: boolean;
  /** Enable the bounded arrival collector and negotiated reporting packets. */
  deliveryTimeline?: boolean;
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
  // Concealment is logged at INFO. Enable it only for the bounded terminal
  // diagnostic collector; raw stderr remains inside the guardian process.
  const args = buildFfmpegArgs(spec, {
    ...options,
    decoderDiagnostics: Boolean(options.onTerminal),
    packetTiming: Boolean(options.onTerminal && options.packetTiming),
    decodedGeometry: Boolean(options.onTerminal && options.decodedGeometry),
  });
  const encoderTiming = options.encoderTiming
    ? new EncoderTimingTelemetry(options.monotonicNow)
    : undefined;
  const decodedVideo = new DecodedVideoTelemetry(options.monotonicNow);
  const decoderCadence = new DecoderCadenceTelemetry(options.monotonicNow);
  const decoderDelivery = options.deliveryTimeline
    ? new DecoderDeliveryTelemetry(options.monotonicNow)
    : undefined;
  const decodedHistory = encoderTiming
    ? new DecodedFrameHistory(options.monotonicNow, encoderTiming.scopeID, spec.profile?.fps)
    : undefined;
  const processingWindows = encoderTiming ? new WorkerProcessingWindows() : undefined;
  const lifetime = options.onTerminal ? new DecodedVideoLifetime() : undefined;
  let telemetryEOF = false;
  let diagnostics: EncoderDiagnosticSnapshot | undefined;
  let packetTiming: WorkerPacketTimingSnapshot | undefined;
  let decodedGeometry: DecodedGeometrySnapshot | undefined;
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
        decoderCadence: decoderCadence.snapshot(),
        telemetryEOF,
        ...(diagnostics ? { diagnostics } : {}),
        ...(packetTiming ? { packetTiming } : {}),
        ...(decodedGeometry ? { decodedGeometry } : {}),
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
    decoderCadence.end();
    decoderDelivery?.end();
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
  let overlay: OverlayFeed | undefined;
  try {
    child = fork(new URL('./pipeline-guardian.mjs', import.meta.url), [], {
      execArgv: [],
      stdio: ['ignore', 'pipe', 'ignore', 'ipc', 'pipe', 'pipe', 'pipe'],
    });
    // Guardian fd6 is handed to FFmpeg as stdin: the scorebug overlay input.
    const overlaySink = child.stdio.at(6) as Writable | null | undefined;
    overlay = overlaySink
      ? new OverlayFeed({
          scoreFile: spec.scoreFile,
          size: overlaySize(spec),
          sink: overlaySink,
          ...(options.monotonicNow ? { now: options.monotonicNow } : {}),
          onEvent: (event) => {
            try {
              log.warn(event, { gameId: spec.gameId });
            } catch {}
          },
        })
      : undefined;
    // Guardian IPC remains fd3; fd4 becomes FFmpeg decoded telemetry fd3,
    // and fd5 becomes the independent encoder timing fd4. Always drain both.
    const timingPipe = child.stdio.at(5) as Readable;
    observeEncoderTimingPipe(timingPipe, encoderTiming);
    // Guardian IPC remains fd3; its fd4 becomes FFmpeg's telemetry fd3.
    // Always drain, including after invalid evidence and without an observer.
    const telemetry = child.stdio[4] as Readable;
    observeDecodedPipe(
      telemetry,
      [
        decodedVideo,
        decoderCadence,
        ...(decoderDelivery ? [decoderDelivery] : []),
        ...(lifetime ? [lifetime] : []),
        ...(decodedHistory ? [decodedHistory] : []),
        ...(overlay ? [overlay.observer] : []),
      ],
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
        packetTiming?: WorkerPacketTimingSnapshot;
        decodedGeometry?: DecodedGeometrySnapshot;
      };
      if (event.event === 'exit') {
        encoderExit = { code: event.code, signal: event.signal };
        diagnostics = event.diagnostics;
        packetTiming = event.packetTiming;
        decodedGeometry =
          options.onTerminal && options.decodedGeometry ? event.decodedGeometry : undefined;
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
      overlay?.stop();
      decodedVideo.end();
      decoderCadence.end();
      decoderDelivery?.end();
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
      packetTiming: Boolean(options.onTerminal && options.packetTiming),
      decodedGeometry: Boolean(options.onTerminal && options.decodedGeometry),
    });
    void overlay?.start();
  } catch {
    overlay?.stop();
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
      decoderCadence: decoderCadence.snapshot(),
      ...(decoderDelivery ? { decoderDelivery: decoderDelivery.packet() } : {}),
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
    snapshotDecoderCadence: () => decoderCadence.snapshot(),
    snapshotDecoderDelivery: () => decoderDelivery?.snapshot() ?? null,
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
