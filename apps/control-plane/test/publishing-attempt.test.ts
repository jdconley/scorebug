import { createHmac } from 'node:crypto';
import { expect, it } from 'vitest';
import { deriveIngestGrant } from '../src/ingest.js';
import { publishAttemptQuery, verifyPublishAttemptQuery } from '../src/publishing-attempt.js';

const secret = 'installation-secret-not-production';
const selection = {
  workerId: 'mac',
  outputId: 'local',
  captureDeviceId: 'phone',
  recordingId: 'archive',
};
const path = deriveIngestGrant(secret, 'match', selection, 1, 'localhost', 8890).path;
const attempt = '11111111-2222-4333-8444-555555555555';
const second = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';

it('signs the exact bounded domain/path/attempt identity, independently of relay endpoints', () => {
  const digest = createHmac('sha256', secret)
    .update(JSON.stringify(['scorebug-publish-attempt-v1', path, attempt]))
    .digest('hex');
  expect(publishAttemptQuery(secret, path, attempt)).toBe(`sbp1=${attempt}.${digest}`);
  expect(publishAttemptQuery(secret, path, attempt)).toBe(
    publishAttemptQuery(secret, path, attempt),
  );
  expect(publishAttemptQuery(secret, path, second)).not.toBe(
    publishAttemptQuery(secret, path, attempt),
  );
  expect(verifyPublishAttemptQuery(secret, path, `sbp1=${attempt}.${digest}`)).toBe(attempt);
  expect(verifyPublishAttemptQuery(secret, path, publishAttemptQuery(secret, path, second))).toBe(
    second,
  );
});

it('rejects a genuine query when installation, match, generation or selected identities differ', () => {
  const query = publishAttemptQuery(secret, path, attempt);
  const paths = [
    deriveIngestGrant(secret, 'other-match', selection, 1, 'localhost', 8890).path,
    deriveIngestGrant(secret, 'match', selection, 2, 'localhost', 8890).path,
    ...Object.keys(selection).map(
      (key) =>
        deriveIngestGrant(secret, 'match', { ...selection, [key]: 'other' }, 1, 'localhost', 8890)
          .path,
    ),
  ];
  for (const other of paths)
    expect(verifyPublishAttemptQuery(secret, other, query)).toBeUndefined();
  expect(verifyPublishAttemptQuery('another-installation-secret', path, query)).toBeUndefined();
});

it.each([
  '',
  'a',
  'A'.repeat(36),
  'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeeE',
  `${attempt}\n`,
  `${attempt}x`,
  '1'.repeat(10000),
  null,
  7,
])('refuses malformed signing attempt %j', (value) => {
  expect(() => publishAttemptQuery(secret, path, value as string)).toThrow(
    'invalid_ingest_identity',
  );
});

it('rejects malformed signing scope and leaves invalid verification unknown', () => {
  for (const [key, scope] of [
    ['short', path],
    [secret, 'fixture'],
    [secret, `${path}\n`],
    ['', ''],
  ]) {
    expect(() => publishAttemptQuery(key!, scope!, attempt)).toThrow('invalid_ingest_identity');
    expect(verifyPublishAttemptQuery(key!, scope!, 'invalid')).toBeUndefined();
  }
});

it('rejects relabeled, malformed, duplicated, oversized and legacy private queries', () => {
  const query = publishAttemptQuery(secret, path, attempt);
  for (const invalid of [
    undefined,
    null,
    5,
    {},
    [],
    '',
    'legacy=value',
    `publish:${path}`,
    query.replace(attempt, second),
    query.toUpperCase(),
    query.replace('sbp1=', 'sbp2='),
    query.slice(0, -1),
    `${query}0`,
    `${query}\n`,
    `${query}&extra=1`,
    `${query}&${query}`,
    `other=1&${query}`,
    query.replace('.', '%2E'),
    `sbp1=${attempt}.${'0'.repeat(64)}`,
    'x'.repeat(100000),
  ]) {
    expect(verifyPublishAttemptQuery(secret, path, invalid)).toBeUndefined();
  }
});
