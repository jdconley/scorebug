import { createHmac, timingSafeEqual } from 'node:crypto';

export const PUBLISHING_ATTEMPT_ID_PATTERN = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/;
const pathPattern = /^scorebug-[a-f0-9]{16}-[a-f0-9]{32}$/;
const queryPattern = /^sbp1=([0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})\.([0-9a-f]{64})$/;
const validScope = (secret: string, path: string) =>
  typeof secret === 'string' &&
  secret.length >= 16 &&
  typeof path === 'string' &&
  path.length === 58 &&
  pathPattern.test(path);

/** Private identity attestation, not new authorization, freshness or revocation. */
export function publishAttemptQuery(secret: string, path: string, attempt: string): string {
  if (
    !validScope(secret, path) ||
    typeof attempt !== 'string' ||
    attempt.length !== 36 ||
    !PUBLISHING_ATTEMPT_ID_PATTERN.test(attempt)
  )
    throw new Error('invalid_ingest_identity');
  const proof = createHmac('sha256', secret)
    .update(JSON.stringify(['scorebug-publish-attempt-v1', path, attempt]))
    .digest('hex');
  return `sbp1=${attempt}.${proof}`;
}

/** Return only the authenticated UUID. Never retain a private query in public state. */
export function verifyPublishAttemptQuery(
  secret: string,
  path: string,
  query: unknown,
): string | undefined {
  if (!validScope(secret, path) || typeof query !== 'string' || query.length !== 106)
    return undefined;
  const match = queryPattern.exec(query);
  if (!match) return undefined;
  const expected = publishAttemptQuery(secret, path, match[1]!).slice(-64);
  return timingSafeEqual(Buffer.from(match[2]!, 'hex'), Buffer.from(expected, 'hex'))
    ? match[1]
    : undefined;
}
