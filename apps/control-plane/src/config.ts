import { z } from 'zod';
import { isIngestEndpointHost } from './ingest-endpoint.js';

const workerId = z.string().regex(/^[A-Za-z0-9_-]{1,128}$/);

const schema = z
  .object({
    /**
     * Server-only key for match credentials and SRT secrets. Never a bearer
     * token: owner phones authenticate with device tokens from setup links.
     */
    SERVER_SECRET: z.string().min(16),
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
    /**
     * The worker a broadcast goes to when the phone does not name one. Unset:
     * the one connected worker. Compose passes the worker's own values.
     */
    WORKER_ID: workerId.optional(),
    OUTPUT_ID: workerId.optional(),
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
    if ((config.WORKER_ID === undefined) !== (config.OUTPUT_ID === undefined))
      context.addIssue({
        code: 'custom',
        path: [config.WORKER_ID === undefined ? 'WORKER_ID' : 'OUTPUT_ID'],
        message: 'Set WORKER_ID and OUTPUT_ID together',
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
  return schema.parse({
    ...env,
    PUBLIC_URL: env.PUBLIC_URL || undefined,
    WORKER_ID: env.WORKER_ID || undefined,
    OUTPUT_ID: env.OUTPUT_ID || undefined,
  });
}
