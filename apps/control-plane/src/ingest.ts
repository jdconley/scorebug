import { createHmac } from 'node:crypto';
import { isIP } from 'node:net';
import { z } from 'zod';
import { isIngestEndpoint, type IngestEndpoint } from './ingest-endpoint.js';
import { formatSrtUrl } from './srt-url.js';
import type { BroadcastSelection } from '@scorebug/protocol';

const pathPattern = /^scorebug-[a-f0-9]{16}-[a-f0-9]{32}$/;
const identifier = /^[A-Za-z0-9_-]{1,128}$/;
export function ingestPathPrefix(secret: string): string {
  if (secret.length < 16) throw new Error('invalid_ingest_identity');
  const identity = createHmac('sha256', secret)
    .update(JSON.stringify(['scorebug-ingest-v1', 'installation', '']))
    .digest('hex')
    .slice(0, 16);
  return `scorebug-${identity}-`;
}
export type IngestGrant = {
  path: string;
  publishPassphrase: string;
  readPassphrase: string;
  publishUrl: string;
  readUrl: string;
};
export type SourceObservation = { ready: boolean; inboundBytes: number; tracks: string[] };

/** Deterministic capabilities survive API restart, but change with every broadcast generation. */
export function deriveIngestGrant(
  installationSecret: string,
  gameId: string,
  selection: BroadcastSelection,
  generation: number,
  host: string,
  port: number,
  publishPeerLatencyMs?: number,
  publishPacing?: 'relative',
  publishEndpoint?: IngestEndpoint,
): IngestGrant {
  if (
    installationSecret.length < 16 ||
    ![
      gameId,
      selection.workerId,
      selection.outputId,
      selection.captureDeviceId,
      selection.recordingId,
    ].every((value) => identifier.test(value)) ||
    !Number.isSafeInteger(generation) ||
    generation < 1 ||
    !(isIP(host) || /^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$/.test(host)) ||
    !Number.isInteger(port) ||
    port < 1 ||
    port > 65535 ||
    (publishPeerLatencyMs !== undefined &&
      (!Number.isInteger(publishPeerLatencyMs) ||
        publishPeerLatencyMs < 120 ||
        publishPeerLatencyMs > 2000)) ||
    (publishPacing !== undefined && publishPacing !== 'relative') ||
    (publishEndpoint !== undefined && !isIngestEndpoint(publishEndpoint))
  )
    throw new Error('invalid_ingest_identity');
  const hmac = (domain: string, identity = '') =>
    createHmac('sha256', installationSecret)
      .update(JSON.stringify(['scorebug-ingest-v1', domain, identity]))
      .digest('hex');
  const identity = JSON.stringify([
    gameId,
    selection.workerId,
    selection.outputId,
    selection.captureDeviceId,
    selection.recordingId,
    generation,
  ]);
  const path = `${ingestPathPrefix(installationSecret)}${hmac('path', identity).slice(0, 32)}`;
  const publishPassphrase = hmac('publish', identity),
    readPassphrase = hmac('read', identity);
  const url = (action: string, passphrase: string) => {
    const endpoint = action === 'publish' && publishEndpoint ? publishEndpoint : { host, port };
    const authorityHost = isIP(endpoint.host) === 6 ? `[${endpoint.host}]` : endpoint.host;
    const result = new URL(`srt://${authorityHost}:${endpoint.port}`);
    result.searchParams.set('streamid', `${action}:${path}`);
    result.searchParams.set('passphrase', passphrase);
    result.searchParams.set('pkt_size', '1316');
    // The native SDK consumes socket-option milliseconds, unlike FFmpeg URL microseconds.
    if (action === 'publish' && publishPeerLatencyMs !== undefined)
      result.searchParams.set('peerlatency', String(publishPeerLatencyMs));
    if (action === 'publish' && publishPacing === 'relative') result.searchParams.set('maxbw', '0');
    return formatSrtUrl(result);
  };
  return {
    path,
    publishPassphrase,
    readPassphrase,
    publishUrl: url('publish', publishPassphrase),
    readUrl: url('read', readPassphrase),
  };
}

const observation = z.object({
  online: z.boolean(),
  available: z.boolean(),
  inboundBytes: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER),
  source: z.object({ type: z.string() }).nullable(),
  tracks2: z.array(
    z.object({
      codec: z.enum([
        'AV1',
        'VP9',
        'VP8',
        'H265',
        'H264',
        'MPEG-4 Video',
        'MPEG-1/2 Video',
        'M-JPEG',
        'Opus',
        'FLAC',
        'Vorbis',
        'MPEG-4 Audio',
        'MPEG-4 Audio LATM',
        'MPEG-1/2 Audio',
        'AC3',
        'Speex',
        'G726',
        'G722',
        'G711',
        'LPCM',
        'MPEG-TS',
        'KLV',
        'Generic',
      ]),
    }),
  ),
});

/** Private MediaMTX v1.21 API adapter. Never includes remote bodies or credentialed URLs in errors. */
export class IngestRelay {
  async list(prefix: string): Promise<string[]> {
    if (!/^scorebug-[a-f0-9]{16}-$/.test(prefix)) throw new Error('invalid_relay_prefix');
    const paths = new Set<string>();
    for (let page = 0; page < 10; page++) {
      const response = await this.request(
        'GET',
        `v3/config/paths/list?page=${page}&itemsPerPage=100`,
      );
      if (response.status !== 200) throw new Error(`relay_http_${response.status}`);
      const parsed = z
        .object({
          pageCount: z.number().int().min(0).max(10),
          items: z.array(z.object({ name: z.string() })).max(100),
        })
        .safeParse(response.body);
      if (!parsed.success) throw new Error('relay_invalid_response');
      for (const { name } of parsed.data.items)
        if (name.startsWith(prefix) && pathPattern.test(name)) paths.add(name);
      if (page + 1 >= parsed.data.pageCount) return [...paths];
    }
    throw new Error('relay_invalid_response');
  }
  private readonly base: URL;
  private readonly authorization: string;
  private readonly timeoutMs: number;
  constructor(options: { apiUrl: string; username: string; password: string; timeoutMs?: number }) {
    try {
      this.base = new URL(options.apiUrl);
    } catch {
      throw new Error('invalid_relay_configuration');
    }
    this.timeoutMs = options.timeoutMs ?? 2000;
    if (
      !['http:', 'https:'].includes(this.base.protocol) ||
      this.base.username ||
      this.base.password ||
      this.base.search ||
      this.base.hash ||
      !options.username ||
      options.username.includes(':') ||
      !options.password ||
      !Number.isInteger(this.timeoutMs) ||
      this.timeoutMs < 1 ||
      this.timeoutMs > 30_000
    )
      throw new Error('invalid_relay_configuration');
    this.base.pathname = this.base.pathname.replace(/\/$/, '') + '/';
    this.authorization = `Basic ${Buffer.from(`${options.username}:${options.password}`).toString('base64')}`;
  }
  private path(path: string): string {
    if (!pathPattern.test(path)) throw new Error('invalid_relay_path');
    return path;
  }
  private async request(
    method: string,
    path: string,
    body?: unknown,
  ): Promise<{ status: number; body: unknown }> {
    try {
      const response = await fetch(new URL(path, this.base), {
        method,
        headers: {
          authorization: this.authorization,
          'content-type': 'application/json',
          'cache-control': 'no-cache, no-store',
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        signal: AbortSignal.timeout(this.timeoutMs),
        redirect: 'error',
      });
      // Error bodies may contain credentials. Do not parse or propagate them.
      if (!response.ok) {
        await response.body?.cancel();
        return { status: response.status, body: null };
      }
      return { status: response.status, body: await response.json() };
    } catch {
      throw new Error('relay_unavailable');
    }
  }
  async ensure(grant: IngestGrant): Promise<void> {
    const path = this.path(grant.path);
    if (
      ![grant.publishPassphrase, grant.readPassphrase].every((value) =>
        /^[a-f0-9]{64}$/.test(value),
      ) ||
      grant.publishPassphrase === grant.readPassphrase
    )
      throw new Error('invalid_ingest_credentials');
    const config = {
      source: 'publisher',
      overridePublisher: false,
      alwaysAvailable: false,
      record: false,
      srtPublishPassphrase: grant.publishPassphrase,
      srtReadPassphrase: grant.readPassphrase,
    };
    const verify = (body: unknown) => {
      if (
        !body ||
        typeof body !== 'object' ||
        (body as Record<string, unknown>).scorebugDrain === true ||
        !Object.entries(config).every(
          ([key, value]) => (body as Record<string, unknown>)[key] === value,
        )
      )
        throw new Error('relay_path_conflict');
    };
    const existing = await this.request('GET', `v3/config/paths/get/${path}`);
    if (existing.status === 200) {
      verify(existing.body);
      return;
    }
    if (existing.status !== 404) throw new Error(`relay_http_${existing.status}`);
    const added = await this.request('POST', `v3/config/paths/add/${path}`, config);
    if (added.status === 200) return;
    // An identical concurrent provisioner may have created the path after our read.
    if (added.status === 400) {
      const raced = await this.request('GET', `v3/config/paths/get/${path}`);
      if (raced.status === 200) {
        verify(raced.body);
        return;
      }
    }
    throw new Error(`relay_http_${added.status}`);
  }
  /** Revoke new admissions immediately, preserving only the bounded accepted stream. */
  async retire(path: string): Promise<void> {
    path = this.path(path);
    try {
      const patched = await this.request('PATCH', `v3/config/paths/patch/${path}`, {
        scorebugDrain: true,
      });
      if (patched.status === 404) return;
      if (patched.status !== 200) throw new Error(`relay_http_${patched.status}`);
      const verified = await this.request('GET', `v3/config/paths/get/${path}`);
      if (verified.status === 404) return;
      if (verified.status !== 200) throw new Error(`relay_http_${verified.status}`);
      if ((verified.body as { scorebugDrain?: unknown } | null)?.scorebugDrain !== true)
        throw new Error('relay_invalid_response');
      // The relay itself enforces an eight-second hard deadline, including API outages.
      // Reconciliation removes the retired configuration once its source has closed.
      if (!(await this.status(path)).ready) await this.remove(path);
    } catch (error) {
      // Older/unreachable relays must never leave old grants admitting connections.
      await this.remove(path);
      throw error;
    }
  }
  async remove(path: string): Promise<void> {
    const result = await this.request('DELETE', `v3/config/paths/delete/${this.path(path)}`);
    if (![200, 404].includes(result.status)) throw new Error(`relay_http_${result.status}`);
  }
  async status(path: string): Promise<SourceObservation> {
    const response = await this.request('GET', `v3/paths/get/${this.path(path)}`);
    if (response.status === 404) return { ready: false, inboundBytes: 0, tracks: [] };
    if (response.status !== 200) throw new Error(`relay_http_${response.status}`);
    const parsed = observation.safeParse(response.body);
    if (!parsed.success) throw new Error('relay_invalid_response');
    const value = parsed.data;
    return {
      ready:
        value.online &&
        value.available &&
        value.source?.type === 'srtConn' &&
        value.inboundBytes > 0 &&
        value.tracks2.length > 0,
      inboundBytes: value.inboundBytes,
      tracks: value.tracks2.map((track) => track.codec),
    };
  }
}
