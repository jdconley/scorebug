import { describe, expect, it } from 'vitest';
import { WorkerPacketTiming } from '../src/worker-packet-timing.mjs';
const packet = (pts = '0', seconds = '0', dts = pts, dtsSeconds = seconds) => ({
  pts,
  ptsSeconds: seconds,
  dts,
  dtsSeconds,
});
const demux = (media = 'audio', pts = '-2112', seconds = '-0.044') => {
  const index = media === 'audio' ? 1 : 0;
  return `[${media[0]}ist#0:${index}/${media === 'audio' ? 'aac' : 'h264'} @ 0x74cc4c480] [info] demuxer -> ist_index:0:${index} type:${media} pkt_pts:${pts} pkt_pts_time:${seconds} pkt_dts:${pts} pkt_dts_time:${seconds} duration:1024 duration_time:0.0213333\n`;
};
const mux = (media = 'audio', pts = '-23', seconds = '-0.023', codec = 'aac') => {
  const index = media === 'audio' ? 1 : 0;
  return `[${media[0]}ost#0:${index}/${codec} @ 0x74cd10300] [info] muxer <- pts:${pts} pts_time:${seconds} dts:${pts} dts_time:${seconds} duration:23 duration_time:0.023 size:287 latency(total:128.367ms, encode-mux: 128.367ms/100%)\n`;
};
const push = (tracker: WorkerPacketTiming, value: string) =>
  tracker.push(new TextEncoder().encode(value));

describe('WorkerPacketTiming diagnostic numeric prefix', () => {
  it('starts with an explicitly diagnostic, empty independent snapshot', () => {
    expect(new WorkerPacketTiming().snapshot()).toEqual({
      formatVersion: 1,
      diagnosticOnly: true,
      maximumPacketsPerLane: 128,
      ended: false,
      pipeError: false,
      drainTimedOut: false,
      incompleteLine: false,
      malformedRows: 0,
      oversizedLines: 0,
      demux: { video: { packetCount: 0, first: [] }, audio: { packetCount: 0, first: [] } },
      mux: { video: { packetCount: 0, first: [] }, audio: { packetCount: 0, first: [] } },
    });
  });
  it('frames byte chunks with sampled negative audio and encoded video in both directions', () => {
    const tracker = new WorkerPacketTiming();
    const input =
      demux() +
      mux() +
      demux('video', '0', '0').replace('[info] ', '') +
      mux('video', '0', '0', 'h264_videotoolbox').replace('\n', '\r\n') +
      mux('video', '33', '0.033', 'libx264') +
      mux('video', '67', '0.067', 'h264_nvenc').replace('[info] ', '');
    for (const byte of new TextEncoder().encode(input)) tracker.push(Uint8Array.of(byte));
    tracker.end();
    const result = tracker.snapshot();
    expect(result.demux.audio).toEqual({ packetCount: 1, first: [packet('-2112', '-0.044')] });
    expect(result.mux.audio).toEqual({ packetCount: 1, first: [packet('-23', '-0.023')] });
    expect(result.demux.video.first).toEqual([packet()]);
    expect(result.mux.video.first).toEqual([
      packet(),
      packet('33', '0.033'),
      packet('67', '0.067'),
    ]);
    expect(result).toMatchObject({ ended: true, malformedRows: 0, incompleteLine: false });
  });
  it('keeps exactly the unchanged first 128 packets per lane and counts later packets', () => {
    const tracker = new WorkerPacketTiming();
    for (let i = 0; i < 128; i++)
      for (const media of ['audio', 'video'])
        push(tracker, demux(media, String(i), String(i)) + mux(media, String(i), String(i)));
    const prefix = tracker.snapshot();
    expect(prefix.demux.audio.first).toHaveLength(128);
    for (let i = 128; i < 140; i++)
      for (const media of ['audio', 'video'])
        push(tracker, demux(media, String(i), String(i)) + mux(media, String(i), String(i)));
    const result = tracker.snapshot();
    for (const stage of ['demux', 'mux'] as const)
      for (const media of ['audio', 'video'] as const) {
        expect(result[stage][media].packetCount).toBe(140);
        expect(result[stage][media].first).toEqual(prefix[stage][media].first);
        expect(result[stage][media].first[0]).toEqual(packet());
        expect(result[stage][media].first[127]).toEqual(packet('127', '127'));
      }
  });
  it('retains exact wide signed timestamps, finite bounded seconds, and distinct DTS', () => {
    const tracker = new WorkerPacketTiming();
    push(
      tracker,
      mux('audio', '9223372036854775807', '1.234e+20')
        .replace('dts:9223372036854775807', 'dts:-9223372036854775807')
        .replace('dts_time:1.234e+20', 'dts_time:-1e-20'),
    );
    expect(tracker.snapshot().mux.audio.first).toEqual([
      packet('9223372036854775807', '1.234e+20', '-9223372036854775807', '-1e-20'),
    ]);
  });
  it.each([
    'N/A',
    'NaN',
    'Infinity',
    '+1',
    '-0',
    '01',
    '0x10',
    '1.5',
    '1e2',
    '-9223372036854775808',
    '9223372036854775808',
    '-9223372036854775809',
    '12345678901234567890',
  ])('rejects invalid timestamp %s', (value) => {
    const tracker = new WorkerPacketTiming();
    push(tracker, demux('audio', value) + mux().replace('dts:-23', `dts:${value}`));
    expect(tracker.snapshot()).toMatchObject({
      malformedRows: 2,
      demux: { audio: { packetCount: 0 } },
      mux: { audio: { packetCount: 0 } },
    });
  });
  it.each([
    'NaN',
    'Infinity',
    '+0.1',
    '00.1',
    '.1',
    '1.',
    '1e999',
    '1e1000',
    '1'.repeat(21),
    '0.' + '1'.repeat(21),
  ])('rejects noncanonical, nonfinite, or overlong seconds %s', (value) => {
    const tracker = new WorkerPacketTiming();
    push(
      tracker,
      demux('audio', '0', value) + mux().replace('dts_time:-0.023', `dts_time:${value}`),
    );
    expect(tracker.snapshot().malformedRows).toBe(2);
    expect(tracker.snapshot().demux.audio.packetCount).toBe(0);
    expect(tracker.snapshot().mux.audio.packetCount).toBe(0);
  });
  it('rejects index, media, direction, prefix and field mismatches without retaining secrets', () => {
    const tracker = new WorkerPacketTiming();
    const invalid = [
      demux().replace('aist#0:1', 'aist#0:0'),
      demux().replace('ist_index:0:1', 'ist_index:0:0'),
      demux().replace('type:audio', 'type:video'),
      mux().replace('aost#0:1', 'aost#0:0'),
      demux().replace('aist#0:1', 'aist#1:1'),
      mux().replace('aost#0:1', 'aist#0:1'),
      mux().replace('pts:-23', 'pts:https://private.example/SECRET'),
      mux().replace('/aac @', '/secret-codec @'),
      mux().replace('[info]', '[debug]'),
      'SECRET ' + demux(),
    ];
    for (const line of invalid) push(tracker, line);
    push(
      tracker,
      '[info] unrelated private rtmp://private.example/SECRET\n' +
        demux().replace('demuxer ->', 'demuxer+ffmpeg ->') +
        demux().replace('demuxer ->', 'demuxer+tsfixup ->') +
        mux().replace('muxer <-', 'encoder ->'),
    );
    push(tracker, mux().replace('latency(', 'SECRET rtmp://private.example/ latency('));
    const result = tracker.snapshot();
    expect(result.malformedRows).toBe(invalid.length);
    expect(result.mux.audio).toEqual({ packetCount: 1, first: [packet('-23', '-0.023')] });
    expect(JSON.stringify(result)).not.toMatch(/SECRET|private|aac|0x74|latency|payload/);
    expect(result).not.toHaveProperty('recognized');
  });
  it('accepts exactly 4096 bytes and drops the entire oversized line through its newline', () => {
    const tracker = new WorkerPacketTiming();
    const line = mux().trimEnd();
    push(tracker, line.padEnd(4096, ' ') + '\n');
    push(tracker, line.padEnd(4097, ' '));
    push(tracker, mux() + mux());
    expect(tracker.snapshot()).toMatchObject({
      oversizedLines: 1,
      malformedRows: 0,
      mux: { audio: { packetCount: 2 } },
    });
  });
  it('marks but does not parse incomplete input, including an oversized tail', () => {
    for (const tail of [mux().trimEnd(), 'x'.repeat(5000)]) {
      const tracker = new WorkerPacketTiming();
      push(tracker, tail);
      tracker.end();
      expect(tracker.snapshot()).toMatchObject({
        ended: true,
        incompleteLine: true,
        mux: { audio: { packetCount: 0 } },
      });
    }
  });
  it('tracks pipe and drain failures as booleans without retaining errors', () => {
    const tracker = new WorkerPacketTiming();
    tracker.failPipe();
    tracker.timeOutDrain();
    expect(tracker.snapshot()).toMatchObject({ pipeError: true, drainTimedOut: true });
    tracker.end();
    expect(tracker.snapshot()).toMatchObject({ ended: true, pipeError: true, drainTimedOut: true });
  });
  it('ends idempotently, ignores further input and returns deep clones', () => {
    const tracker = new WorkerPacketTiming();
    push(tracker, demux());
    const result = tracker.snapshot();
    result.demux.audio.first[0].pts = '999';
    result.demux.audio.first.push(packet());
    result.demux.audio.packetCount = 100;
    tracker.end();
    const ended = tracker.snapshot();
    tracker.end();
    push(tracker, demux());
    expect(tracker.snapshot()).toEqual(ended);
    expect(ended.demux.audio).toEqual({ packetCount: 1, first: [packet('-2112', '-0.044')] });
  });
});
