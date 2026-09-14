import { z } from 'zod';

const schema = z.object({
  CONTROL_PLANE_WS: z.string().url(),
  HOME_TOKEN: z.string().min(16),
  RTMP_TARGET: z.string().min(8),
  NVENC_ENABLED: z
    .string()
    .default('true')
    .transform((v) => v.toLowerCase() === 'true'),
  FFMPEG_PATH: z.string().min(1).default('ffmpeg'),
  FFPROBE_PATH: z.string().min(1).default('ffprobe'),
  FONT_PATH: z.string().min(1).default('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'),
  SCORE_DIR: z.string().default('/tmp/scorebug'),
  LOG_LEVEL: z.enum(['debug', 'info', 'warn', 'error']).default('info'),
});

export type Config = z.infer<typeof schema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  return schema.parse(env);
}
