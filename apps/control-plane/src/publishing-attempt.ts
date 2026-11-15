import { createHmac } from 'node:crypto';

export const PUBLISHING_ATTEMPT_ID_PATTERN = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/;
const pathPattern = /^scorebug-[a-f0-9]{16}-[a-f0-9]{32}$/;

/** Stream-id query naming the phone's publishing attempt (`sbp1=<attempt>.<hmac>`).
 * The iOS app requires it in the publish URL it receives; the relay ignores it.
 * It is not authorization: the per-generation SRT passphrase is. */
export function publishAttemptQuery(secret: string, path: string, attempt: string): string {
  if (
    typeof secret !== 'string' ||
    secret.length < 16 ||
    typeof path !== 'string' ||
    !pathPattern.test(path) ||
    typeof attempt !== 'string' ||
    !PUBLISHING_ATTEMPT_ID_PATTERN.test(attempt)
  )
    throw new Error('invalid_ingest_identity');
  const proof = createHmac('sha256', secret)
    .update(JSON.stringify(['scorebug-publish-attempt-v1', path, attempt]))
    .digest('hex');
  return `sbp1=${attempt}.${proof}`;
}
