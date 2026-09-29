import { expect, it, vi } from 'vitest';
import * as diagnostics from '../src/worker-terminal.js';
import { EncoderDiagnostics } from '../src/encoder-diagnostics.mjs';
import type { Logger } from '../src/logger.js';

const fixture = () => {
  const records: unknown[] = [];
  const append = (msg: string, meta?: Record<string, unknown>) => records.push({ msg, ...meta });
  const log: Logger = { debug: append, info: append, warn: append, error: append };
  return { log, records };
};

it.each([undefined, '', '0', 'true', '01', '1 ', ' 1'])(
  'requires the exact diagnostic flag (%s)',
  (flag) => {
    const { log, records } = fixture();
    const factory = diagnostics.createWorkerTerminalDiagnostics(log, flag);
    const scope = factory.scope({ gameId: 'game', generation: 5 });
    expect(factory.enabled).toBe(false);
    expect(scope.log).toBe(log);
    expect(scope.onTerminal).toBeUndefined();
    expect(records).toEqual([]);
  },
);

it('assigns worker-local ordinals across retries and scopes pipeline events and terminal', () => {
  const { log, records } = fixture();
  const factory = diagnostics.createWorkerTerminalDiagnostics(log, '1');
  const parser = new EncoderDiagnostics();
  parser.push(Buffer.from('Error during demuxing: Input/output error\n'));
  parser.end();
  for (const generation of [5, 5, 6]) {
    const scope = factory.scope({ gameId: 'game', generation });
    scope.log.info('ffmpeg_spawning', { gameId: 'wrong', nvenc: false });
    scope.onTerminal?.({
      diagnostics: parser.snapshot(),
      telemetryEOF: true,
      encoderExit: null,
      outputProgress: null,
      decodedVideo: {
        acceptedFrames: 0,
        freshFrames: 0,
        duplicateFrames: 0,
        reorderedFrames: 0,
        firstPTS: null,
        lastPTS: null,
        highestPTS: null,
        timeBase: '1/90000',
        invalidReason: null,
        ended: true,
      },
    });
  }
  expect(factory.enabled).toBe(true);
  expect(records).toHaveLength(6);
  for (let i = 0; i < 3; i++) {
    expect(records[2 * i]).toMatchObject({
      msg: 'ffmpeg_spawning',
      gameId: 'game',
      generation: i === 2 ? 6 : 5,
      pipelineOrdinal: i + 1,
    });
    expect(records[2 * i + 1]).toMatchObject({
      diagnostics: parser.snapshot(),
      msg: 'worker_pipeline_terminal',
      gameId: 'game',
      generation: i === 2 ? 6 : 5,
      pipelineOrdinal: i + 1,
      encoderExit: null,
    });
  }
});

it('joins diagnostic stdout flush and bounds a stalled callback', async () => {
  vi.useFakeTimers();
  try {
    let callback: (() => void) | undefined;
    let resolved = false;
    const output = {
      write: (_: string, cb: () => void) => {
        callback = cb;
        return true;
      },
    };
    const flushed = diagnostics.flushWorkerDiagnostics(output).then(() => {
      resolved = true;
    });
    await Promise.resolve();
    expect(resolved).toBe(false);
    callback?.();
    await flushed;
    expect(resolved).toBe(true);
    const stalled = diagnostics.flushWorkerDiagnostics({ write: () => true });
    await vi.advanceTimersByTimeAsync(250);
    await stalled;
    expect(vi.getTimerCount()).toBe(0);
  } finally {
    vi.useRealTimers();
  }
});

it('routes diagnostic warnings and errors through the real logger stdout channel only when enabled', async () => {
  const { createLogger } = await import('../src/logger.js');
  const info = vi.spyOn(console, 'info').mockImplementation(() => {});
  const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
  const error = vi.spyOn(console, 'error').mockImplementation(() => {});
  try {
    const log = createLogger('info');
    const enabled = diagnostics
      .createWorkerTerminalDiagnostics(log, '1')
      .scope({ gameId: 'game', generation: 2 });
    enabled.log.warn('ffmpeg_terminal_callback_failed');
    enabled.log.error('ffmpeg_guardian_lost');
    expect(info.mock.calls.map(([line]) => JSON.parse(line))).toEqual([
      expect.objectContaining({
        msg: 'ffmpeg_terminal_callback_failed',
        gameId: 'game',
        generation: 2,
        pipelineOrdinal: 1,
      }),
      expect.objectContaining({
        msg: 'ffmpeg_guardian_lost',
        gameId: 'game',
        generation: 2,
        pipelineOrdinal: 1,
      }),
    ]);
    expect(warn).not.toHaveBeenCalled();
    expect(error).not.toHaveBeenCalled();
    const disabled = diagnostics
      .createWorkerTerminalDiagnostics(log, undefined)
      .scope({ gameId: 'game', generation: 2 });
    disabled.log.warn('ffmpeg_terminal_callback_failed');
    disabled.log.error('ffmpeg_guardian_lost');
    expect(info).toHaveBeenCalledTimes(2);
    expect(warn).toHaveBeenCalledTimes(1);
    expect(error).toHaveBeenCalledTimes(1);
  } finally {
    vi.restoreAllMocks();
  }
});

it('keeps terminal log records small when optional processing histories are present', () => {
  const f = fixture();
  const terminal: any = {
    telemetryEOF: true,
    encoderExit: { code: 0, signal: null },
    outputProgress: null,
    decodedVideo: {
      acceptedFrames: 0,
      freshFrames: 0,
      duplicateFrames: 0,
      reorderedFrames: 0,
      firstPTS: null,
      lastPTS: null,
      highestPTS: null,
      timeBase: '1/90000',
      invalidReason: null,
      ended: true,
    },
    decodedFrameHistory: {
      frames: Array.from({ length: 512 }, (_, i) => ({ pts: i * 3000, observedAt: i * 33 })),
    },
    encoderTiming: {
      frames: Array.from({ length: 256 }, (_, i) => ({
        pts: String(i),
        submittedAt: i,
        completedAt: i + 1,
      })),
    },
  };
  diagnostics.createWorkerTerminalDiagnostics(f.log, '1').scope({ gameId: 'game', generation: 1 })
    .onTerminal!(terminal);
  expect(f.records[0]).not.toHaveProperty('decodedFrameHistory');
  expect(f.records[0]).not.toHaveProperty('encoderTiming');
  expect(JSON.stringify(f.records[0]).length).toBeLessThan(4096);
});

it('requires both explicit flags for packet diagnostics', () => {
  for (const [terminalFlag, packetFlag, enabled] of [
    [undefined, '1', false],
    ['1', undefined, false],
    ['1', 'true', false],
    ['1', '1', true],
  ] as const) {
    const f = fixture();
    expect(
      (diagnostics.createWorkerTerminalDiagnostics as any)(f.log, terminalFlag, packetFlag)
        .packetTimingEnabled,
    ).toBe(enabled);
  }
});

it('emits bounded scoped packet prefixes separately from terminal media history', () => {
  const f = fixture();
  const lane = () => ({
    packetCount: 200,
    last: Array.from({ length: 128 }, (_, i) => ({
      pts: String(i + 72),
      ptsSeconds: String((i + 72) / 30),
      dts: String(i + 72),
      dtsSeconds: String((i + 72) / 30),
      duration: '1',
      durationSeconds: '0.0333333',
    })),
    first: Array.from({ length: 128 }, (_, i) => ({
      pts: String(i),
      ptsSeconds: String(i / 30),
      dts: String(i),
      dtsSeconds: String(i / 30),
    })),
  });
  const packetTiming = {
    formatVersion: 2,
    diagnosticOnly: true,
    maximumPacketsPerLane: 128,
    ended: true,
    pipeError: false,
    drainTimedOut: false,
    incompleteLine: false,
    malformedRows: 0,
    oversizedLines: 0,
    demux: { video: lane(), audio: lane() },
    mux: { video: lane(), audio: lane() },
  };
  const terminal: any = {
    packetTiming,
    telemetryEOF: true,
    encoderExit: { code: 0, signal: null },
    outputProgress: null,
    decodedVideo: {
      acceptedFrames: 0,
      freshFrames: 0,
      duplicateFrames: 0,
      reorderedFrames: 0,
      firstPTS: null,
      lastPTS: null,
      highestPTS: null,
      timeBase: '1/90000',
      invalidReason: null,
      ended: true,
    },
  };
  (diagnostics.createWorkerTerminalDiagnostics as any)(f.log, '1', '1')
    .scope({ gameId: 'game', generation: 1 })
    .onTerminal(terminal);
  const records = f.records as any[];
  const chunks = records.filter((r) => r.msg === 'worker_packet_timing');
  expect(chunks).toHaveLength(64);
  const tails = records.filter((r) => r.msg === 'worker_packet_tail');
  expect(tails).toHaveLength(64);
  for (const stage of ['demux', 'mux'] as const)
    for (const media of ['video', 'audio'] as const) {
      const parts = tails.filter((r) => r.stage === stage && r.media === media);
      expect(parts.map((r) => r.firstPacketIndex)).toEqual(
        Array.from({ length: 16 }, (_, i) => 72 + i * 8),
      );
      expect(parts.flatMap((r) => r.packets)).toEqual(packetTiming[stage][media].last);
    }
  for (const stage of ['demux', 'mux'])
    for (const media of ['video', 'audio']) {
      const parts = chunks.filter((r) => r.stage === stage && r.media === media);
      expect(parts.map((r) => r.firstPacketIndex)).toEqual(
        Array.from({ length: 16 }, (_, i) => i * 8),
      );
      expect(parts.flatMap((r) => r.packets)).toEqual(
        packetTiming[stage as 'demux'][media as 'video'].first,
      );
      expect(
        parts.every(
          (r) => r.packetCount === 200 && r.retainedPackets === 128 && r.diagnosticOnly === true,
        ),
      ).toBe(true);
    }
  expect(records.every((r) => JSON.stringify(r).length < 4096)).toBe(true);
  expect(
    records.every((r) => r.gameId === 'game' && r.generation === 1 && r.pipelineOrdinal === 1),
  ).toBe(true);
  expect(records.find((r) => r.msg === 'worker_pipeline_terminal')).not.toHaveProperty(
    'packetTiming',
  );
});

it('gates geometry by both exact flags and emits only scoped bounded numeric runs', async () => {
  const { DecodedGeometry } = await import('../src/decoded-geometry.mjs');
  for (const [flag, geometryFlag, enabled] of [
    [undefined, '1', false],
    ['1', undefined, false],
    ['1', 'true', false],
    ['1', '1', true],
  ] as const) {
    const f = fixture();
    const factory = (diagnostics.createWorkerTerminalDiagnostics as any)(
      f.log,
      flag,
      undefined,
      geometryFlag,
    );
    expect(factory.decodedGeometryEnabled).toBe(enabled);
    const parser = new DecodedGeometry();
    parser.end();
    const geometry: any = parser.snapshot();
    geometry.secret = 'SECRET';
    const terminal: any = {
      decodedGeometry: geometry,
      decodedVideo: {},
      telemetryEOF: true,
      encoderExit: { code: 0, signal: null },
      outputProgress: null,
    };
    factory.scope({ gameId: 'game', generation: 3 }).onTerminal?.(terminal);
    if (enabled) {
      const row = (f.records as any[]).find((r) => r.msg === 'worker_decoded_geometry');
      expect(row).toMatchObject({
        gameId: 'game',
        generation: 3,
        pipelineOrdinal: 1,
        runIndex: null,
        runCount: 0,
        observedFrames: 0,
        invalidReason: 'time_base',
        ended: true,
      });
      geometry.runs = Array.from({ length: 64 }, (_, i) => ({
        width: 1280,
        height: 720,
        firstOrdinal: i,
        lastOrdinal: i,
        firstPTS: i * 3000,
        lastPTS: i * 3000,
        frames: 1,
        maximumPTSDelta: 0,
        secret: 'SECRET',
      }));
      geometry.observedFrames = 64;
      factory.scope({ gameId: 'game', generation: 4 }).onTerminal(terminal);
      const rows = (f.records as any[]).filter(
        (r) => r.msg === 'worker_decoded_geometry' && r.generation === 4,
      );
      expect(rows).toHaveLength(64);
      expect(rows.map((r) => r.runIndex)).toEqual(Array.from({ length: 64 }, (_, i) => i));
      expect(
        rows.every(
          (r) => r.pipelineOrdinal === 2 && r.runCount === 64 && JSON.stringify(r).length < 4096,
        ),
      ).toBe(true);
    } else
      expect((f.records as any[]).some((r) => r.msg === 'worker_decoded_geometry')).toBe(false);
    expect(JSON.stringify(f.records)).not.toContain('SECRET');
    expect(
      (f.records as any[])
        .filter((r) => r.msg === 'worker_pipeline_terminal')
        .every((r) => !('decodedGeometry' in r)),
    ).toBe(true);
  }
});

it.each([
  undefined,
  '',
  'ABCDEFAB-cdef-abcd-efab-cdefabcdefab',
  '11111111-1111-4111-8111-111111111111\n',
  '11111111-1111-4111-8111-111111111111',
])('emits only a validated pipeline digest on terminal and geometry for %j', (pipelineReadId) => {
  const f = fixture();
  const scope = diagnostics
    .createWorkerTerminalDiagnostics(f.log, '1', undefined, '1')
    .scope({ gameId: 'game', generation: 2 }, { pipelineReadId });
  scope.onTerminal!({
    decodedVideo: {} as any,
    telemetryEOF: true,
    encoderExit: null,
    outputProgress: null,
    decodedGeometry: {
      formatVersion: 1,
      diagnosticOnly: true,
      timeBase: '1/90000',
      maximumRuns: 64,
      ended: true,
      invalidReason: 'time_base',
      observedFrames: 0,
      runs: [],
    },
  });
  expect(f.records).toHaveLength(2);
  for (const record of f.records as any[]) {
    expect(record.pipelineReadKey).toBe(
      pipelineReadId === '11111111-1111-4111-8111-111111111111'
        ? '5d75f38b3e289ae59af50a3cf51905342960e21554535120e565416c63d0e4f2'
        : undefined,
    );
    expect(record).not.toHaveProperty('pipelineReadId');
  }
  expect(JSON.stringify(f.records)).not.toContain('11111111-1111');
});
