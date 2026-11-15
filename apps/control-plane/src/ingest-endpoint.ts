import { isIP } from 'node:net';

export type IngestEndpoint = { host: string; port: number };

/** Accept raw IP literals or DNS names, never URL authority syntax. */
export function isIngestEndpointHost(host: unknown): host is string {
  if (typeof host !== 'string' || /[\s%]/.test(host)) return false;
  if (isIP(host)) return true;
  const name = host.endsWith('.') ? host.slice(0, -1) : host;
  return (
    name.length > 0 &&
    name.length <= 253 &&
    name.split('.').every((label) => /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/.test(label))
  );
}

export function isIngestEndpoint(value: unknown): value is IngestEndpoint {
  if (!value || typeof value !== 'object') return false;
  const endpoint = value as Partial<IngestEndpoint>;
  return (
    isIngestEndpointHost(endpoint.host) &&
    typeof endpoint.port === 'number' &&
    Number.isInteger(endpoint.port) &&
    endpoint.port >= 1 &&
    endpoint.port <= 65535
  );
}
