import { randomUUID } from 'node:crypto';
import { publishAttemptQuery } from '../src/publishing-attempt.js';
import type { Config } from '../src/config.js';
import type { MatchStore } from '../src/matches-store.js';

export function testConfig(overrides: Partial<Config> = {}): Config {
  return {
    SERVER_SECRET: 'server-secret-1234567890abcdef',
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

/** Enroll an owner phone the way a setup link does and return its device token. */
export function ownerToken(matches: MatchStore): string {
  const { code } = matches.account.mintSetupCode();
  return matches.account.redeemSetupCode({ code, deviceId: randomUUID(), deviceName: 'Test phone' })
    .token;
}

export function phoneAuth(token: string) {
  return { authorization: `Bearer ${token}` };
}

/** The attempt a `sbp1=` publish tag names, if the tag is genuine for this path. */
export function attemptOf(secret: string, path: string, query: string | undefined) {
  const attempt = query?.slice(5, 41);
  return attempt && query === publishAttemptQuery(secret, path, attempt) ? attempt : undefined;
}
