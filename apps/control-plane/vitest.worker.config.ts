import { join } from 'node:path';
import { cloudflareTest, readD1Migrations } from '@cloudflare/vitest-plugin';
import { defineConfig } from 'vitest/config';

export default defineConfig(async () => {
  const migrations = await readD1Migrations(join(import.meta.dirname, 'migrations'));
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: './wrangler.jsonc' },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            ADMIN_EMAILS: 'admin@example.com',
            GOOGLE_CLIENT_ID: 'test-client-id.apps.googleusercontent.com',
            GOOGLE_CLIENT_SECRET: 'test-client-secret',
            SERVER_SECRET: 'test-server-secret-0123456789abcdef',
            STREAM_API_TOKEN: 'test-stream-token',
          },
        },
      }),
    ],
    test: {
      include: ['test-worker/**/*.test.ts'],
      setupFiles: ['./test-worker/apply-migrations.ts'],
      // Each test runs real Durable Objects and D1 in workerd; on a loaded CI runner a few take
      // around 7 s, past Vitest's 5 s default.
      testTimeout: 30_000,
    },
  };
});
