import type { WorkerEncoder } from './worker-processing.js';

export const WORKER_OUTPUT_PROFILES = [
  '240p30',
  '360p30',
  '540p30',
  '720p30',
  '1080p30',
  '2160p30',
] as const;
/** A short local encode proves initialization, never sustainable input capacity. */
export type WorkerCapabilities = {
  version: 1;
  outputId: string;
  encoder: WorkerEncoder;
  outputProfile: (typeof WORKER_OUTPUT_PROFILES)[number];
  outputMode: 'rtmp' | 'record' | 'rtmp+record';
  startup: 'passed' | 'failed' | 'timeout' | 'cancelled' | 'unsupported_platform';
  sustainedPerformance: 'unqualified';
};
export type WorkerCapabilitiesResponse = {
  workerId: string;
  state: 'unknown' | 'stale' | 'fresh';
  validForMs: number;
  capabilities: WorkerCapabilities | null;
  serverTime: string;
};
