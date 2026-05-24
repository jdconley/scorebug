import { createApp } from '../src/app.js';
import type { Config } from '../src/config.js';
import { createLogger } from '../src/logger.js';
import { GameStore } from '../src/state.js';
import { HomeBus, type HomeSocket } from '../src/home-bus.js';

export function testConfig(overrides: Partial<Config> = {}): Config {
  return {
    PHONE_TOKEN: 'phone-token-1234567890abcdef',
    HOME_TOKEN: 'home-token-1234567890abcdef',
    INTERNAL_TOKEN: 'internal-token-1234567890abcdef',
    PORT: 0,
    HOST: '127.0.0.1',
    INGEST_HOST: 'ingest.test',
    INGEST_PORT: 8890,
    LOG_LEVEL: 'error',
    CORS_ORIGINS: '*',
    ...overrides,
  };
}

export class FakeHomeSocket implements HomeSocket {
  readonly sent: string[] = [];
  closed = false;
  send(data: string): void {
    this.sent.push(data);
  }
  close(): void {
    this.closed = true;
  }
}

export function buildTestApp(config = testConfig()) {
  const log = createLogger('error');
  const store = new GameStore();
  const bus = new HomeBus(log);
  const { app } = createApp(config, { log, store, bus });
  return { app, config, store, bus, log };
}

export function phoneAuth(token: string) {
  return { authorization: `Bearer ${token}` };
}
