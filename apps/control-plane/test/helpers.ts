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
