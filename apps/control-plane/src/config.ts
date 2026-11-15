import { z } from 'zod';
import { isIngestEndpointHost } from './ingest-endpoint.js';

const schema = z
  .object({
    PHONE_TOKEN: z.string().min(16),
    HOME_TOKEN: z.string().min(16),
    PORT: z.coerce.number().int().min(0).max(65535).default(8787),
    HOST: z.string().default('0.0.0.0'),
    /**
     * SRT host the worker reads from (and the phone publishes to unless
     * INGEST_PUBLISH_HOST is set). Required whenever a relay is configured;
     * relay-less development falls back to loopback.
     */
    INGEST_HOST: z.string().refine(isIngestEndpointHost).optional(),
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
    /**
     * Public HTTPS base for setup and invite links, e.g. https://scorebug.example.com.
     * Required to mint links (the request's Host header is never used); compose
     * requires it and install.sh always writes it.
     */
    PUBLIC_URL: z
      .string()
      .url()
      .refine((value) => {
        const url = new URL(value);
        return ['http:', 'https:'].includes(url.protocol) && !url.search && !url.hash;
      })
      .optional(),
    RELAY_API_URL: z.string().url().optional(),
    RELAY_API_USERNAME: z.string().min(1).optional(),
    RELAY_API_PASSWORD: z.string().min(1).optional(),
  })
  .superRefine((config, context) => {
    if (config.RELAY_API_URL !== undefined && config.INGEST_HOST === undefined)
      context.addIssue({
        code: 'custom',
        path: ['INGEST_HOST'],
        message: 'INGEST_HOST is required when a relay is configured',
      });
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
  })
  .transform((config) => ({ ...config, INGEST_HOST: config.INGEST_HOST ?? '127.0.0.1' }));

export type Config = z.infer<typeof schema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  // Compose passes `${PUBLIC_URL:-}`: empty means unset.
  return schema.parse({ ...env, PUBLIC_URL: env.PUBLIC_URL || undefined });
}
