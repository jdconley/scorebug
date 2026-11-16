import { fileURLToPath } from 'node:url';
import { cloudflareTest, readD1Migrations } from '@cloudflare/vitest-plugin';
import { defineConfig } from 'vitest/config';

export default defineConfig(async () => {
  const migrations = await readD1Migrations(
    fileURLToPath(new URL('./migrations', import.meta.url)),
  );
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
    },
  };
});
