import { z } from 'zod';

const schema = z
  .object({
    CONTROL_PLANE_URL: z.string().url(),
    HOME_TOKEN: z.string().min(16),
    WORKER_ID: z.string().regex(/^[A-Za-z0-9_-]{1,128}$/),
    OUTPUT_ID: z.string().regex(/^[A-Za-z0-9_-]{1,128}$/),
    OUTPUT_MODE: z.enum(['rtmp', 'record', 'rtmp+record']).default('rtmp'),
    OUTPUT_RECORDING_DIR: z
      .string()
      .refine((value) => value.trim().length > 0)
      .optional(),
    /**
     * Fallback RTMP(S) destination for matches the control plane assigns no
     * destination; optional because destinations normally come from the server.
     */
    OUTPUT_URL: z
      .string()
      .url()
      .refine((value) => ['rtmp:', 'rtmps:'].includes(new URL(value).protocol))
      .optional(),
    ENCODER: z.enum(['software', 'videotoolbox', 'nvenc']),
    DECODER_THREADING: z.enum(['automatic', 'slice']).default('automatic'),
    WORKER_REPORT_INTERVAL_MS: z.coerce.number().int().min(100).max(4000).default(1000),
    VIDEO_PROFILE: z
      .enum(['240p30', '360p30', '540p30', '720p30', '1080p30', '2160p30'])
      .default('1080p30'),
    FFMPEG_PATH: z.string().min(1).default('ffmpeg'),
    FFPROBE_PATH: z.string().min(1).default('ffprobe'),
    SCORE_DIR: z.string().default('/tmp/scorebug'),
    LOG_LEVEL: z.enum(['debug', 'info', 'warn', 'error']).default('info'),
  })
  .superRefine((config, context) => {
    if (config.OUTPUT_MODE !== 'rtmp' && !config.OUTPUT_RECORDING_DIR)
      context.addIssue({
        code: 'custom',
        path: ['OUTPUT_RECORDING_DIR'],
        message: 'Recording output requires OUTPUT_RECORDING_DIR',
      });
  });

export type Config = z.infer<typeof schema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  return schema.parse({
    ...env,
    // Compose passes `${OUTPUT_URL:-}`: empty means "no fallback".
    OUTPUT_URL: env.OUTPUT_URL || undefined,
    ENCODER: env.ENCODER ?? (env.NVENC_ENABLED?.toLowerCase() === 'true' ? 'nvenc' : 'software'),
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
