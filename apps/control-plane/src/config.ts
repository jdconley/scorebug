import { z } from 'zod';

const schema = z.object({
  PHONE_TOKEN: z.string().min(16),
  HOME_TOKEN: z.string().min(16),
  INTERNAL_TOKEN: z.string().min(16),
  PORT: z.coerce.number().int().positive().default(8787),
  HOST: z.string().default('0.0.0.0'),
  INGEST_HOST: z.string().default('ingest.scorebug.live'),
  INGEST_PORT: z.coerce.number().int().positive().default(8890),
  LOG_LEVEL: z.enum(['debug', 'info', 'warn', 'error']).default('info'),
  /** Comma-separated origins for CORS. `*` allows any. Default `*` for personal-scale use. */
  CORS_ORIGINS: z.string().default('*'),
});

export type Config = z.infer<typeof schema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  return schema.parse(env);
}
