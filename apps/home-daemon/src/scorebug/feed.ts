import { readFile } from 'node:fs/promises';
import type { Writable } from 'node:stream';
import type { ScorebugOverlay } from '@scorebug/protocol';
import { DecodedVideoParser } from '../decoded-video.js';
import type { DecodedPipeObserver } from '../decoded-pipe.js';
import { overlayRegions, packRegions, type OverlayRegions, type OverlaySize } from './layout.js';
import { MatroskaFramer, matroskaHeader } from './matroska.js';
import { renderScorebugRgba, transparentFrame } from './render.js';
import { parseScorebugOverlay } from './state.js';

/**
 * Streams the scorebug into FFmpeg's second input as timestamped RGBA frames.
 *
 * FFmpeg's `overlay` pairs each main frame with the newest overlay frame whose
 * timestamp is not later, and it holds main frames until it has seen an
 * overlay frame beyond them. The live graph keeps the camera's transport PTS
 * (`-copyts`), so each overlay frame is stamped from the decoder telemetry:
 * latest decoded PTS, advanced by elapsed wall time, plus a small lead. A
 * score change therefore appears `leadMs` (+ up to one interval) after it is
 * rendered, and the main video never waits as long as frames keep arriving.
 * If this feed stops, FFmpeg sees EOF and `eof_action=pass` drops the overlay
 * instead of stalling or ending the broadcast.
 */
export type OverlayFeedOptions = {
  scoreFile: string;
  size: OverlaySize;
  sink: Writable;
  /** Monotonic milliseconds. */
  now?: () => number;
  intervalMs?: number;
  leadMs?: number;
  read?: (path: string) => Promise<string>;
  render?: (state: ScorebugOverlay, size: OverlaySize) => Promise<Buffer>;
  onEvent?: (event: 'overlay_render_failed' | 'overlay_sink_failed') => void;
};

export const OVERLAY_INTERVAL_MS = 125;
export const OVERLAY_LEAD_MS = 250;

export class OverlayFeed {
  readonly observer: DecodedPipeObserver;
  private readonly now: () => number;
  private readonly intervalMs: number;
  private readonly leadMs: number;
  private readonly read: (path: string) => Promise<string>;
  private readonly render: (state: ScorebugOverlay, size: OverlaySize) => Promise<Buffer>;
  private readonly framer = new MatroskaFramer();
  private readonly layout: OverlayRegions;
  private frame: Buffer;
  private text: string | undefined;
  private latest: { pts: number; at: number } | undefined;
  private lastTimestamp: number | undefined;
  private timer: ReturnType<typeof setInterval> | undefined;
  private refreshing: Promise<void> | undefined;
  private started = false;
  private streaming = false;
  private stopped = false;
  private renderFailed = false;
  framesWritten = 0;

  constructor(private readonly options: OverlayFeedOptions) {
    this.now = options.now ?? (() => performance.now());
    this.intervalMs = options.intervalMs ?? OVERLAY_INTERVAL_MS;
    this.leadMs = options.leadMs ?? OVERLAY_LEAD_MS;
    this.read = options.read ?? ((path) => readFile(path, 'utf8'));
    this.render = options.render ?? renderScorebugRgba;
    this.layout = overlayRegions(options.size);
    this.frame = transparentFrame(this.canvas);
    const parser = new DecodedVideoParser(
      (pts) => {
        this.latest = { pts, at: this.now() };
      },
      // Invalid telemetry stops PTS updates; frames keep advancing on wall time.
      () => undefined,
    );
    this.observer = {
      push: (chunk) => parser.push(chunk),
      end: () => parser.end(),
      invalidatePipe: () => undefined,
    };
    options.sink.on('error', () => this.fail());
  }

  /** The packed per-style boxes of the output frame: what FFmpeg receives. */
  get canvas(): OverlaySize {
    return this.layout.canvas;
  }

  /** Renders the current score file first so FFmpeg's first overlay frame is already drawn. */
  async start(): Promise<void> {
    if (this.started || this.stopped) return;
    this.started = true;
    await this.refresh();
    if (this.stopped) return;
    this.write(matroskaHeader(this.canvas.width, this.canvas.height));
    this.streaming = true;
    // FFmpeg cannot configure its graph without this frame: never skip it.
    this.emitFrame(true);
    this.timer = setInterval(() => {
      void this.refresh();
      this.emitFrame();
    }, this.intervalMs);
    this.timer.unref?.();
  }

  stop(): void {
    if (this.stopped) return;
    this.stopped = true;
    clearInterval(this.timer);
    this.options.sink.end();
  }

  /** Overlay timestamp in ms on the decoder's transport clock; strictly increasing. */
  nextTimestamp(): number {
    const latest = this.latest;
    const target = latest
      ? Math.floor(latest.pts / 90) + Math.max(0, this.now() - latest.at) + this.leadMs
      : 0;
    const timestamp = Math.max(
      this.lastTimestamp === undefined ? 0 : this.lastTimestamp + 1,
      Math.floor(target),
    );
    this.lastTimestamp = timestamp;
    return timestamp;
  }

  private fail() {
    if (this.stopped) return;
    this.options.onEvent?.('overlay_sink_failed');
    this.stop();
  }

  private write(chunk: Buffer) {
    try {
      this.options.sink.write(chunk);
    } catch {
      this.fail();
    }
  }

  private emitFrame(force = false) {
    // Respect backpressure: FFmpeg only drains overlay frames as main video advances.
    const sink = this.options.sink;
    if (!this.streaming || this.stopped || sink.destroyed) return;
    if (sink.writableLength > 0 && !force) return;
    for (const part of this.framer.frame(this.nextTimestamp(), this.frame)) this.write(part);
    this.framesWritten++;
  }

  private refresh(): Promise<void> {
    this.refreshing ??= this.load().finally(() => {
      this.refreshing = undefined;
    });
    return this.refreshing;
  }

  private async load(): Promise<void> {
    let text: string;
    try {
      text = await this.read(this.options.scoreFile);
    } catch {
      return; // Not written yet: keep the current frame.
    }
    if (text === this.text || this.stopped) return;
    const state = parseScorebugOverlay(text);
    try {
      this.frame = state
        ? packRegions(await this.render(state, this.options.size), this.options.size, this.layout)
        : transparentFrame(this.canvas);
      this.text = text;
      this.renderFailed = false;
    } catch {
      if (!this.renderFailed) this.options.onEvent?.('overlay_render_failed');
      this.renderFailed = true;
      return;
    }
    // Show a change at the next frame rather than the next interval.
    this.emitFrame();
  }
}
