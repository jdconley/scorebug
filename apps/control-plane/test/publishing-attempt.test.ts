import { createHmac } from 'node:crypto';
import { expect, it } from 'vitest';
import { deriveIngestGrant } from '../src/ingest.js';
import { publishAttemptQuery } from '../src/publishing-attempt.js';

const secret = 'installation-secret-not-production';
const selection = {
  workerId: 'mac',
  outputId: 'local',
  captureDeviceId: 'phone',
  recordingId: 'archive',
};
const path = deriveIngestGrant(secret, 'match', selection, 1, 'localhost', 8890).path;
const attempt = '11111111-2222-4333-8444-555555555555';

it('tags the publish stream id in the exact form the iOS app validates', () => {
  const digest = createHmac('sha256', secret)
    .update(JSON.stringify(['scorebug-publish-attempt-v1', path, attempt]))
    .digest('hex');
  const query = publishAttemptQuery(secret, path, attempt);
  expect(query).toBe(`sbp1=${attempt}.${digest}`);
  // ios/Packages/ScorebugCore MatchHTTPClient.publishAccess
  expect(`publish:${path}:${query}`).toMatch(
    new RegExp(`^publish:scorebug-[0-9a-f]{16}-[0-9a-f]{32}:sbp1=${attempt}\\.[0-9a-f]{64}$`),
  );
  expect(publishAttemptQuery(secret, path, 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee')).not.toBe(query);
});

it.each([
  ['short secret', 'short', path, attempt],
  ['foreign path', secret, 'other-path', attempt],
  ['uppercase attempt', secret, path, 'AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE'],
  ['malformed attempt', secret, path, 'attempt'],
])('rejects a %s', (_, s, p, a) => {
  expect(() => publishAttemptQuery(s, p, a)).toThrow('invalid_ingest_identity');
});
