import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { expect, it } from 'vitest';
import * as outputs from '../src/output-recording.js';

it('allocates a fresh private recording directory for every pipeline attempt', () => {
  const root = mkdtempSync(join(tmpdir(), 'scorebug-recordings-'));
  try {
    const config = {
      OUTPUT_MODE: 'rtmp+record' as const,
      OUTPUT_RECORDING_DIR: join(root, "video's | archive"),
      OUTPUT_URL: 'rtmps://host/live/key',
    };
    const first = outputs.allocatePipelineOutputs(config);
    expect(first.publishUrl).toBe(config.OUTPUT_URL);
    expect(first.recordingPath).toBe(resolve(first.recordingPath!));
    expect(statSync(dirname(first.recordingPath!)).mode & 0o777).toBe(0o700);
    expect(existsSync(first.recordingPath!)).toBe(false);
    writeFileSync(first.recordingPath!, 'earlier recording');
    const retry = outputs.allocatePipelineOutputs(config);
    expect(retry.recordingPath).not.toBe(first.recordingPath);
    expect(readFileSync(first.recordingPath!, 'utf8')).toBe('earlier recording');
    expect(
      outputs.allocatePipelineOutputs({ ...config, OUTPUT_MODE: 'record' }).publishUrl,
    ).toBeUndefined();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

it('allocates nothing for RTMP-only mode and propagates recording directory failures', () => {
  const root = mkdtempSync(join(tmpdir(), 'scorebug-recordings-'));
  try {
    const recordingDir = join(root, 'unused');
    expect(
      outputs.allocatePipelineOutputs({
        OUTPUT_MODE: 'rtmp',
        OUTPUT_URL: 'rtmp://host/live/key',
        OUTPUT_RECORDING_DIR: recordingDir,
      }),
    ).toEqual({ publishUrl: 'rtmp://host/live/key' });
    expect(existsSync(recordingDir)).toBe(false);
    const file = join(root, 'file');
    writeFileSync(file, 'not a directory');
    expect(() =>
      outputs.allocatePipelineOutputs({ OUTPUT_MODE: 'record', OUTPUT_RECORDING_DIR: file }),
    ).toThrow();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

it('prefers the control-plane destination and needs some RTMP URL unless recording only', () => {
  const config = { OUTPUT_MODE: 'rtmp' as const, OUTPUT_URL: 'rtmps://fallback/live/key' };
  expect(outputs.allocatePipelineOutputs(config, 'rtmps://assigned/live/key2')).toEqual({
    publishUrl: 'rtmps://assigned/live/key2',
  });
  expect(outputs.allocatePipelineOutputs(config, null)).toEqual({
    publishUrl: 'rtmps://fallback/live/key',
  });
  expect(() => outputs.allocatePipelineOutputs({ OUTPUT_MODE: 'rtmp' }, null)).toThrow(
    'missing_output_url',
  );
  const root = mkdtempSync(join(tmpdir(), 'scorebug-recordings-'));
  try {
    const recordOnly = outputs.allocatePipelineOutputs(
      { OUTPUT_MODE: 'record', OUTPUT_RECORDING_DIR: root },
      'rtmps://assigned/live/key2',
    );
    expect(recordOnly.publishUrl).toBeUndefined();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
