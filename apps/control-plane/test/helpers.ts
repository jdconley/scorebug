import { publishAttemptQuery } from '../src/publishing-attempt.js';
import type { Config } from '../src/config.js';

export function testConfig(overrides: Partial<Config> = {}): Config {
  return {
    PHONE_TOKEN: 'phone-token-1234567890abcdef',
    HOME_TOKEN: 'home-token-1234567890abcdef',
    PORT: 0,
    HOST: '127.0.0.1',
    INGEST_HOST: 'ingest.test',
    INGEST_PORT: 8890,
    LOG_LEVEL: 'error',
    CORS_ORIGINS: '*',
    DATABASE_PATH: ':memory:',
    ...overrides,
  };
}

export function phoneAuth(token: string) {
  return { authorization: `Bearer ${token}` };
}

/** The attempt a `sbp1=` publish tag names, if the tag is genuine for this path. */
export function attemptOf(secret: string, path: string, query: string | undefined) {
  const attempt = query?.slice(5, 41);
  return attempt && query === publishAttemptQuery(secret, path, attempt) ? attempt : undefined;
}
