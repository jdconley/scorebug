import { z } from 'zod';

const schema = z.object({
  CONTROL_PLANE_URL: z.string().url(),
  HOME_TOKEN: z.string().min(16),
  WORKER_ID: z.string().regex(/^[A-Za-z0-9_-]{1,128}$/),
  OUTPUT_ID: z.string().regex(/^[A-Za-z0-9_-]{1,128}$/),
  VIDEO_PROFILE: z
    .enum(['240p30', '360p30', '540p30', '720p30', '1080p30', '2160p30'])
    .default('1080p30'),
  /** Hold score changes this long so they line up with delayed video (hosted: 1100). */
  SCORE_DELAY_MS: z.coerce.number().int().min(0).max(5000).default(0),
  /** `fast` bounds FFmpeg's input analysis for the known Stream RTMPS source (hosted). */
  INPUT_PROBE: z.enum(['default', 'fast']).default('default'),
  /** Fail an attempt when the source sends nothing for this long; unset waits. */
  INPUT_READ_TIMEOUT_MS: z.coerce.number().int().min(500).max(120_000).optional(),
  /** No new output for this long restarts FFmpeg. */
  OUTPUT_TIMEOUT_MS: z.coerce.number().int().min(1000).max(120_000).default(10_000),
  /** Attempts per minute before the worker waits; see RETRY_FREE_AFTER_MS. */
  RETRY_MAX_ATTEMPTS: z.coerce.number().int().min(1).max(60).default(3),
  /** An attempt that ran this long gives its retry back (source absent, not a crash). */
  RETRY_FREE_AFTER_MS: z.coerce.number().int().min(100).max(120_000).optional(),
  FFMPEG_PATH: z.string().min(1).default('ffmpeg'),
  SCORE_DIR: z.string().default('/tmp/scorebug'),
  LOG_LEVEL: z.enum(['debug', 'info', 'warn', 'error']).default('info'),
});

export type Config = z.infer<typeof schema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  return schema.parse({
    ...env,
    INPUT_READ_TIMEOUT_MS: env.INPUT_READ_TIMEOUT_MS || undefined,
    RETRY_FREE_AFTER_MS: env.RETRY_FREE_AFTER_MS || undefined,
  });
}

export const videoProfiles = {
  '240p30': { width: 426, height: 240, fps: 30, bitrateKbps: 350 },
  '360p30': { width: 640, height: 360, fps: 30, bitrateKbps: 600 },
  '540p30': { width: 960, height: 540, fps: 30, bitrateKbps: 1500 },
  '720p30': { width: 1280, height: 720, fps: 30, bitrateKbps: 3000 },
  '1080p30': { width: 1920, height: 1080, fps: 30, bitrateKbps: 6000 },
  '2160p30': { width: 3840, height: 2160, fps: 30, bitrateKbps: 18000 },
} as const;
