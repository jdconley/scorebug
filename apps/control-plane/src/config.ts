import { z } from 'zod';

const schema = z
  .object({
    PHONE_TOKEN: z.string().min(16),
    HOME_TOKEN: z.string().min(16),
    INTERNAL_TOKEN: z.string().min(16),
    PORT: z.coerce.number().int().min(0).max(65535).default(8787),
    HOST: z.string().default('0.0.0.0'),
    INGEST_HOST: z.string().default('ingest.scorebug.live'),
    INGEST_PORT: z.coerce.number().int().positive().default(8890),
    /** Explicit sender pacing; omitted preserves the native library's default. */
    SRT_PUBLISH_PACING: z.literal('relative').optional(),
    /** Native publisher peer receive delay; omitted preserves SRT negotiation defaults. */
    SRT_PUBLISH_PEER_LATENCY_MS: z.coerce.number().int().min(120).max(2000).optional(),
    LOG_LEVEL: z.enum(['debug', 'info', 'warn', 'error']).default('info'),
    /** Comma-separated origins for CORS. `*` allows any. Default `*` for personal-scale use. */
    CORS_ORIGINS: z.string().default('*'),
    DATABASE_PATH: z.string().min(1).default('data/scorebug.sqlite'),
    RELAY_API_URL: z.string().url().optional(),
    RELAY_API_USERNAME: z.string().min(1).optional(),
    RELAY_API_PASSWORD: z.string().min(1).optional(),
  })
  .superRefine((config, context) => {
    const fields = ['RELAY_API_URL', 'RELAY_API_USERNAME', 'RELAY_API_PASSWORD'] as const;
    if (fields.some((field) => config[field] !== undefined))
      for (const field of fields)
        if (!config[field])
          context.addIssue({
            code: 'custom',
            path: [field],
            message: 'All relay management settings are required together',
          });
  });

export type Config = z.infer<typeof schema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  return schema.parse(env);
}
