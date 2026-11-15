import { PassThrough, Writable } from 'node:stream';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { ScorebugOverlay } from '@scorebug/protocol';
import { OverlayFeed } from '../src/scorebug/feed.js';
import { overlayRegions } from '../src/scorebug/layout.js';
import { scorebugOverlay, serializeScorebugOverlay } from '../src/scorebug/state.js';

const size = { width: 4, height: 8 };
const overlay = (home: number) =>
  serializeScorebugOverlay(
    scorebugOverlay({
      teams: {
        home: { name: 'Home', shortName: 'H', color: '#112233' },
        away: { name: 'Away', shortName: 'A', color: '#445566' },
      },
      score: { home, away: 0, set: 1, homeSets: 0, awaySets: 0 },
    }),
  );

/** Collects writes and decodes SimpleBlock timestamps and first payload byte. */
class Sink extends Writable {
  chunks: Buffer[] = [];
  blocked = false;
  override _write(chunk: Buffer, _encoding: string, callback: () => void) {
    this.chunks.push(chunk);
    if (!this.blocked) callback();
    else this.pending = callback;
  }
  pending: (() => void) | undefined;
  frames(): { timestamp: number; first: number }[] {
    const data = Buffer.concat(this.chunks);
    const frames: { timestamp: number; first: number }[] = [];
    let cluster = 0;
    for (let index = 0; index < data.length - 4; index++) {
      if (data.readUInt32BE(index) === 0x1f43b675 && data[index + 12] === 0xe7) {
        const length = data[index + 13]! & 0x7f;
        cluster = data.readUIntBE(index + 14, length);
      }
      // SimpleBlock with a 1-byte size is impossible here; payloads are large enough
      // to need a multi-byte vint, so match 0xa3 followed by the track/flags pattern.
      if (data[index] === 0xa3) {
        const sizeLength = Math.clz32(data[index + 1]!) - 23;
        const header = index + 1 + sizeLength;
        if (data[header] === 0x81 && data[header + 3] === 0x80) {
          frames.push({
            timestamp: cluster + data.readInt16BE(header + 1),
            first: data[header + 4]!,
          });
          index = header + 4;
        }
      }
    }
    return frames;
  }
}

const feeds: OverlayFeed[] = [];
afterEach(() => {
  for (const feed of feeds.splice(0)) feed.stop();
  vi.useRealTimers();
});

function setup(files: Record<string, string>, options: { now?: () => number } = {}) {
  const sink = new Sink();
  const render = vi.fn(async (state: ScorebugOverlay, full: typeof size) =>
    Buffer.alloc(full.width * full.height * 4, state.score.home + 1),
  );
  const feed = new OverlayFeed({
    scoreFile: 'score.json',
    size,
    sink,
    intervalMs: 1000,
    leadMs: 250,
    read: async (path) => {
      if (!(path in files)) throw new Error('ENOENT');
      return files[path]!;
    },
    render,
    ...(options.now ? { now: options.now } : {}),
  });
  feeds.push(feed);
  return { sink, feed, render };
}
const telemetry = (feed: OverlayFeed, ordinal: number, pts: number) =>
  feed.observer.push(
    Buffer.from(`frame:${ordinal} pts:${pts} pts_time:${pts / 90000}\nscorebug.source=1\n`),
  );

describe('OverlayFeed', () => {
  it('sends only the packed per-style boxes', () => {
    const { feed } = setup({});
    expect(feed.canvas).toEqual(overlayRegions(size).canvas);
  });
  it('renders the score file before the header and first frame at timestamp 0', async () => {
    const { sink, feed, render } = setup({ 'score.json': overlay(4) });
    await feed.start();
    expect(render).toHaveBeenCalledTimes(1);
    const data = Buffer.concat(sink.chunks);
    expect(data.readUInt32BE(0)).toBe(0x1a45dfa3);
    expect(sink.frames()).toEqual([{ timestamp: 0, first: 5 }]);
  });
  it('stamps frames on the decoder clock plus elapsed time and lead, strictly increasing', async () => {
    let now = 1000;
    const { sink, feed } = setup({ 'score.json': overlay(0) }, { now: () => now });
    await feed.start();
    expect(feed.nextTimestamp()).toBe(1); // no telemetry yet: stays behind main
    telemetry(feed, 0, 324_126_000); // 3601.4 s
    expect(feed.nextTimestamp()).toBe(3_601_400 + 250);
    now = 1100;
    expect(feed.nextTimestamp()).toBe(3_601_400 + 100 + 250);
    telemetry(feed, 1, 324_139_000); // 3601.544 s, observed now
    expect(feed.nextTimestamp()).toBe(3_601_544 + 250);
    // Telemetry slightly behind the extrapolation, or a clock stepping backwards,
    // never makes the overlay go backwards.
    telemetry(feed, 2, 324_136_000);
    expect(feed.nextTimestamp()).toBe(3_601_544 + 250 + 1);
    telemetry(feed, 3, 0);
    expect(feed.nextTimestamp()).toBe(3_601_544 + 250 + 2);
    expect(sink.frames().map((frame) => frame.timestamp)).toEqual([0]);
  });
  it('keeps advancing on wall time when telemetry becomes invalid', async () => {
    let now = 0;
    const { feed } = setup({ 'score.json': overlay(0) }, { now: () => now });
    await feed.start();
    telemetry(feed, 0, 90_000);
    feed.observer.push(Buffer.from('garbage\n'));
    telemetry(feed, 1, 900_000);
    now = 5000;
    expect(feed.nextTimestamp()).toBe(1000 + 5000 + 250);
  });
  it('re-renders when the file changes, emits immediately, and ignores unchanged reads', async () => {
    vi.useFakeTimers();
    const files = { 'score.json': overlay(1) };
    const { sink, feed, render } = setup(files);
    await feed.start();
    await vi.advanceTimersByTimeAsync(1000);
    expect(render).toHaveBeenCalledTimes(1);
    expect(sink.frames().map((frame) => frame.first)).toEqual([2, 2]);
    files['score.json'] = overlay(7);
    await vi.advanceTimersByTimeAsync(1000);
    expect(render).toHaveBeenCalledTimes(2);
    // The interval frame goes out with the old image; the change follows at once.
    expect(sink.frames().map((frame) => frame.first)).toEqual([2, 2, 2, 8]);
    const timestamps = sink.frames().map((frame) => frame.timestamp);
    expect(timestamps).toEqual([...timestamps].sort((a, b) => a - b));
    expect(new Set(timestamps).size).toBe(timestamps.length);
  });
  it('draws nothing for a missing or legacy text score file', async () => {
    const legacy = setup({ 'score.json': 'HOME 12 - 7 AWAY' });
    await legacy.feed.start();
    expect(legacy.render).not.toHaveBeenCalled();
    expect(legacy.sink.frames()).toEqual([{ timestamp: 0, first: 0 }]);
    const missing = setup({});
    await missing.feed.start();
    expect(missing.sink.frames()).toEqual([{ timestamp: 0, first: 0 }]);
  });
  it('skips frames while FFmpeg is not draining instead of buffering them', async () => {
    vi.useFakeTimers();
    const { sink, feed } = setup({ 'score.json': overlay(0) });
    sink.blocked = true;
    await feed.start();
    await vi.advanceTimersByTimeAsync(5000);
    expect(feed.framesWritten).toBe(1); // the first frame is always queued
    expect(sink.chunks).toHaveLength(1); // only the header reached the blocked pipe
    sink.blocked = false;
    sink.pending?.();
    await vi.advanceTimersByTimeAsync(1000);
    expect(feed.framesWritten).toBe(2);
  });
  it('keeps the last image when a render fails and reports it once', async () => {
    vi.useFakeTimers();
    const files = { 'score.json': overlay(1) };
    const events: string[] = [];
    const sink = new Sink();
    let fail = false;
    const feed = new OverlayFeed({
      scoreFile: 'score.json',
      size,
      sink,
      intervalMs: 1000,
      read: async () => files['score.json'],
      render: async (state) => {
        if (fail) throw new Error('render');
        return Buffer.alloc(size.width * size.height * 4, state.score.home + 1);
      },
      onEvent: (event) => events.push(event),
    });
    feeds.push(feed);
    await feed.start();
    fail = true;
    files['score.json'] = overlay(9);
    await vi.advanceTimersByTimeAsync(3000);
    expect(events).toEqual(['overlay_render_failed']);
    expect(new Set(sink.frames().map((frame) => frame.first))).toEqual(new Set([2]));
  });
  it('stops on a sink error (FFmpeg gone) and ends the stream on stop', async () => {
    const events: string[] = [];
    const sink = new PassThrough();
    const feed = new OverlayFeed({
      scoreFile: 'score.json',
      size,
      sink,
      read: async () => overlay(0),
      render: async () => Buffer.alloc(size.width * size.height * 4),
      onEvent: (event) => events.push(event),
    });
    await feed.start();
    sink.emit('error', new Error('EPIPE'));
    expect(events).toEqual(['overlay_sink_failed']);
    expect(sink.writableEnded).toBe(true);
    const written = feed.framesWritten;
    feed.stop();
    expect(feed.framesWritten).toBe(written);
  });
});
