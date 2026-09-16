import { expect, it } from 'vitest';
import { loadConfig } from '../src/config.js';
const env = {
  PHONE_TOKEN: 'phone-token-not-production',
  HOME_TOKEN: 'home-token-not-production',
  INTERNAL_TOKEN: 'internal-token-not-production',
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
