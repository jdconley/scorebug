import { expect, it } from 'vitest';
import { loadConfig } from '../src/config.js';
const env = {
  PHONE_TOKEN: 'phone-token-not-production',
  HOME_TOKEN: 'home-token-not-production',
};
it('preserves unset publishing delay and accepts bounded millisecond overrides', () => {
  expect(loadConfig(env).SRT_PUBLISH_PEER_LATENCY_MS).toBeUndefined();
  for (const value of ['120', '400', '2000'])
    expect(
      loadConfig({ ...env, SRT_PUBLISH_PEER_LATENCY_MS: value }).SRT_PUBLISH_PEER_LATENCY_MS,
    ).toBe(Number(value));
});
it('rejects invalid publishing recovery delays', () => {
  for (const value of ['', '0', '119', '2001', '400.5', 'NaN', 'Infinity'])
    expect(() => loadConfig({ ...env, SRT_PUBLISH_PEER_LATENCY_MS: value })).toThrow();
});

it('publishing pacing is explicitly relative or absent', () => {
  expect(loadConfig(env).SRT_PUBLISH_PACING).toBeUndefined();
  expect(loadConfig({ ...env, SRT_PUBLISH_PACING: 'relative' }).SRT_PUBLISH_PACING).toBe(
    'relative',
  );
  for (const value of ['', '0', 'default', 'Relative', ' relative'])
    expect(() => loadConfig({ ...env, SRT_PUBLISH_PACING: value })).toThrow();
});

it('falls back to loopback ingest only when no relay is configured', () => {
  const config = loadConfig(env);
  expect(config.INGEST_HOST).toBe('127.0.0.1');
  expect(config.INGEST_PORT).toBe(8890);
  expect(config.INGEST_PUBLISH_HOST).toBeUndefined();
  expect(config.INGEST_PUBLISH_PORT).toBeUndefined();
});

it.each(['proxy.test', 'localhost', '127.0.0.1', '::1', '2001:db8::1'])(
  'accepts paired publisher endpoint host %s without changing reader configuration',
  (host) => {
    const config = loadConfig({ ...env, INGEST_PUBLISH_HOST: host, INGEST_PUBLISH_PORT: '19990' });
    expect(config.INGEST_PUBLISH_HOST).toBe(host);
    expect(config.INGEST_PUBLISH_PORT).toBe(19990);
    expect(config.INGEST_HOST).toBe('127.0.0.1');
    expect(config.INGEST_PORT).toBe(8890);
  },
);

it('requires an explicit INGEST_HOST when a relay is configured', () => {
  const relay = {
    ...env,
    RELAY_API_URL: 'http://relay.test:9997',
    RELAY_API_USERNAME: 'admin',
    RELAY_API_PASSWORD: 'relay-password',
  };
  expect(() => loadConfig(relay)).toThrow(/INGEST_HOST/);
  expect(loadConfig({ ...relay, INGEST_HOST: 'scorebug.example.com' }).INGEST_HOST).toBe(
    'scorebug.example.com',
  );
  expect(() => loadConfig({ ...relay, INGEST_HOST: 'srt://bad' })).toThrow();
});

it('requires both publisher endpoint settings together', () => {
  for (const partial of [{ INGEST_PUBLISH_HOST: 'proxy.test' }, { INGEST_PUBLISH_PORT: '19990' }])
    expect(() => loadConfig({ ...env, ...partial })).toThrow();
});

it.each([
  '',
  'srt://proxy.test',
  'user@proxy.test',
  'proxy.test/path',
  'proxy.test?x',
  'proxy.test#x',
  'proxy.test:19990',
  '[::1]',
  'fe80::1%eth0',
  ' proxy.test',
  'proxy.test ',
  'proxy.test\n',
  'proxy test',
  '-proxy.test',
  'proxy-.test',
  'proxy..test',
  'proxy_test',
  'a'.repeat(64) + '.test',
  'a.'.repeat(127) + 'a',
])('rejects malformed publisher host %j', (host) => {
  expect(() =>
    loadConfig({ ...env, INGEST_PUBLISH_HOST: host, INGEST_PUBLISH_PORT: '19990' }),
  ).toThrow();
});

it.each(['', '0', '-1', '65536', '19990.5', 'NaN', 'Infinity'])(
  'rejects malformed publisher port %j',
  (port) => {
    expect(() =>
      loadConfig({ ...env, INGEST_PUBLISH_HOST: 'proxy.test', INGEST_PUBLISH_PORT: port }),
    ).toThrow();
  },
);

it.each(['1', '65535'])('accepts publisher port boundary %s', (port) => {
  expect(
    loadConfig({ ...env, INGEST_PUBLISH_HOST: 'proxy.test', INGEST_PUBLISH_PORT: port })
      .INGEST_PUBLISH_PORT,
  ).toBe(Number(port));
});
