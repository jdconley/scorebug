/**
 * AES-256-GCM for secrets at rest in D1 (YouTube refresh tokens and ingest URLs). The key is
 * derived from SERVER_SECRET with HKDF, so rotating SERVER_SECRET makes stored YouTube
 * connections unreadable: they then show as needing a reconnect.
 */
const encoder = new TextEncoder();
const keys = new Map<string, Promise<CryptoKey>>();

function key(secret: string, purpose: string): Promise<CryptoKey> {
  const id = `${purpose}\u0000${secret}`;
  let derived = keys.get(id);
  if (!derived) {
    derived = crypto.subtle
      .importKey('raw', encoder.encode(secret), 'HKDF', false, ['deriveKey'])
      .then((base) =>
        crypto.subtle.deriveKey(
          {
            name: 'HKDF',
            hash: 'SHA-256',
            salt: encoder.encode('scorebug-secret-box-v1'),
            info: encoder.encode(purpose),
          },
          base,
          { name: 'AES-GCM', length: 256 },
          false,
          ['encrypt', 'decrypt'],
        ),
      );
    keys.set(id, derived);
  }
  return derived;
}

const toB64 = (bytes: Uint8Array) => Buffer.from(bytes).toString('base64url');
const fromB64 = (text: string) => new Uint8Array(Buffer.from(text, 'base64url'));

/** `v1.<iv>.<ciphertext>`; `purpose` is bound as associated data. */
export async function seal(secret: string, purpose: string, plaintext: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const sealed = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv, additionalData: encoder.encode(purpose) },
    await key(secret, purpose),
    encoder.encode(plaintext),
  );
  return `v1.${toB64(iv)}.${toB64(new Uint8Array(sealed))}`;
}

/** Null when the value was sealed with another key or purpose, or is malformed. */
export async function open(
  secret: string,
  purpose: string,
  sealed: string,
): Promise<string | null> {
  const [version, iv, body, extra] = sealed.split('.');
  if (version !== 'v1' || !iv || !body || extra !== undefined) return null;
  try {
    const plain = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: fromB64(iv), additionalData: encoder.encode(purpose) },
      await key(secret, purpose),
      fromB64(body),
    );
    return new TextDecoder().decode(plain);
  } catch {
    return null;
  }
}

export const REFRESH_TOKEN = 'youtube-refresh-token';
export const INGEST_URL = 'youtube-ingest-url';
