import assert from 'node:assert/strict';
import { isIPv4 } from 'node:net';
import { networkInterfaces } from 'node:os';

/** Canonical RFC1918 only; also used to restrict a physical proxy's learned peer. */
export function isPrivateLabIPv4(host) {
  if (typeof host !== 'string' || !isIPv4(host)) return false;
  const octets = host.split('.').map(Number);
  return (
    octets[0] === 10 ||
    (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
    (octets[0] === 192 && octets[1] === 168)
  );
}

/** Validate before allocating a server/socket. Never resolve DNS or bind wildcard. */
export function validatePrivateLabBind(host, interfaces = networkInterfaces()) {
  if (host === '127.0.0.1') return host;
  assert(isPrivateLabIPv4(host), 'Invalid private lab bind address');
  assert(
    Object.values(interfaces)
      .flat()
      .some(
        (entry) =>
          entry &&
          entry.internal === false &&
          (entry.family === 'IPv4' || entry.family === 4) &&
          entry.address === host,
      ),
    'Private lab bind must be assigned to a noninternal IPv4 interface',
  );
  return host;
}
