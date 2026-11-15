import { z } from 'zod';
import { isIngestEndpointHost } from './ingest-endpoint.js';

const schema = z
  .object({
    PHONE_TOKEN: z.string().min(16),
    HOME_TOKEN: z.string().min(16),
    PORT: z.coerce.number().int().min(0).max(65535).default(8787),
    HOST: z.string().default('0.0.0.0'),
    INGEST_HOST: z.string().default('ingest.scorebug.live'),
    INGEST_PORT: z.coerce.number().int().positive().default(8890),
    /** Native publisher override; the worker reader retains INGEST_HOST/INGEST_PORT. */
    INGEST_PUBLISH_HOST: z.string().refine(isIngestEndpointHost).optional(),
    INGEST_PUBLISH_PORT: z.coerce.number().int().min(1).max(65535).optional(),
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
    if ((config.INGEST_PUBLISH_HOST === undefined) !== (config.INGEST_PUBLISH_PORT === undefined))
      context.addIssue({
        code: 'custom',
        path: [
          config.INGEST_PUBLISH_HOST === undefined ? 'INGEST_PUBLISH_HOST' : 'INGEST_PUBLISH_PORT',
        ],
        message: 'Both publisher ingest settings are required together',
      });
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
