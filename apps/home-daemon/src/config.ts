import { z } from 'zod';

const schema = z.object({
  CONTROL_PLANE_URL: z.string().url(),
  HOME_TOKEN: z.string().min(16),
  WORKER_ID: z.string().regex(/^[A-Za-z0-9_-]{1,128}$/),
  OUTPUT_ID: z.string().regex(/^[A-Za-z0-9_-]{1,128}$/),
  OUTPUT_URL: z
    .string()
    .url()
    .refine((value) => ['rtmp:', 'rtmps:'].includes(new URL(value).protocol)),
  ENCODER: z.enum(['software', 'videotoolbox', 'nvenc']),
  DECODER_THREADING: z.enum(['automatic', 'slice']).default('automatic'),
  WORKER_REPORT_INTERVAL_MS: z.coerce.number().int().min(100).max(5000).default(1000),
  WORKER_PROCESSING: z.enum(['auto', 'off']).default('auto'),
  VIDEO_PROFILE: z.enum(['360p30', '540p30', '720p30', '1080p30', '2160p30']).default('1080p30'),
  FFMPEG_PATH: z.string().min(1).default('ffmpeg'),
  FFPROBE_PATH: z.string().min(1).default('ffprobe'),
  FONT_PATH: z.string().min(1).default('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'),
  SCORE_DIR: z.string().default('/tmp/scorebug'),
  LOG_LEVEL: z.enum(['debug', 'info', 'warn', 'error']).default('info'),
});

export type Config = z.infer<typeof schema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  return schema.parse({
    ...env,
    ENCODER: env.ENCODER ?? (env.NVENC_ENABLED?.toLowerCase() === 'true' ? 'nvenc' : 'software'),
  });
}

export const videoProfiles = {
  '360p30': { width: 640, height: 360, fps: 30, bitrateKbps: 600 },
  '540p30': { width: 960, height: 540, fps: 30, bitrateKbps: 1500 },
  '720p30': { width: 1280, height: 720, fps: 30, bitrateKbps: 3000 },
  '1080p30': { width: 1920, height: 1080, fps: 30, bitrateKbps: 6000 },
  '2160p30': { width: 3840, height: 2160, fps: 30, bitrateKbps: 18000 },
} as const;
