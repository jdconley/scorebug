// node ios/AppStore/asc.mjs METHOD PATH [json]: the App Store Connect API with the Admin key in
// ~/.appstoreconnect/private_keys (see ios/README.md, Release). Also imported by listing.mjs.
import { createSign, createPrivateKey } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
const KEY_ID = '94P27PRFST', ISSUER = '5e665ade-744c-4c11-9279-6cbdc336d1b1';
const key = createPrivateKey(readFileSync(`${homedir()}/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8`));
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
export function token() {
  const now = Math.floor(Date.now() / 1000);
  const input = `${b64({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' })}.${b64({ iss: ISSUER, iat: now, exp: now + 1100, aud: 'appstoreconnect-v1' })}`;
  const sig = createSign('SHA256').update(input).sign({ key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
  return `${input}.${sig}`;
}
export async function asc(method, path, body) {
  const url = path.startsWith('http') ? path : `https://api.appstoreconnect.apple.com${path}`;
  const res = await fetch(url, { method, headers: { Authorization: `Bearer ${token()}`, 'Content-Type': 'application/json' }, body: body ? (typeof body === 'string' ? body : JSON.stringify(body)) : undefined });
  const text = await res.text();
  return { status: res.status, json: text ? JSON.parse(text) : null };
}
if (import.meta.url === `file://${process.argv[1]}`) {
  const [m, p, b] = process.argv.slice(2);
  const r = await asc(m, p, b);
  console.log(r.status, JSON.stringify(r.json, null, 2));
}
