import { formatSrtUrl } from '../srt-url.js';
import type { Env } from './env.js';

/** Live input names: `scorebug:<teamId>:<gameId>`, so the daily sweep can find their owner. */
export const INPUT_PREFIX = 'scorebug:';
export const inputName = (teamId: string, gameId: string) => `${INPUT_PREFIX}${teamId}:${gameId}`;
export function parseInputName(name: string | null | undefined): {
  teamId: string;
  gameId: string;
} | null {
  if (!name?.startsWith(INPUT_PREFIX)) return null;
  const [teamId, gameId, extra] = name.slice(INPUT_PREFIX.length).split(':');
  return teamId && gameId && extra === undefined ? { teamId, gameId } : null;
}

/** Both URLs carry credentials (passphrase and stream ID). Never log them. */
export type LiveInput = {
  uid: string;
  /** The phone publishes here over SRT. */
  publishUrl: string;
  /** The match container pulls this SRT playback URL. */
  readUrl: string;
};
export type ListedInput = { uid: string; name: string | null; createdAt: number };

export class StreamError extends Error {
  constructor(readonly code: 'stream_unavailable' | 'stream_error') {
    super(code);
  }
}

/** Cloudflare Stream live inputs, behind an interface so tests need no network. */
export interface StreamApi {
  createInput(name: string): Promise<LiveInput>;
  /** Missing inputs are fine. */
  deleteInput(uid: string): Promise<void>;
  /** True while a publisher is connected; null when the input does not exist. */
  connected(uid: string): Promise<boolean | null>;
  listInputs(): Promise<ListedInput[]>;
}

type SrtEndpoint = { url?: string; streamId?: string; passphrase?: string };
type InputResource = {
  uid?: string;
  created?: string;
  meta?: { name?: string };
  srt?: SrtEndpoint;
  srtPlayback?: SrtEndpoint;
  status?: { current?: { state?: string } } | null;
};

function srtUrl(endpoint: SrtEndpoint | undefined): string {
  if (!endpoint?.url || !endpoint.streamId || !endpoint.passphrase)
    throw new StreamError('stream_error');
  const url = new URL(endpoint.url);
  url.search = '';
  url.searchParams.set('passphrase', endpoint.passphrase);
  url.searchParams.set('streamid', endpoint.streamId);
  return formatSrtUrl(url);
}

export function realStream(
  env: Pick<Env, 'CF_ACCOUNT_ID' | 'STREAM_API_TOKEN'>,
  fetcher: typeof fetch = fetch,
): StreamApi {
  async function call<T>(method: string, path: string, body?: unknown): Promise<T | null> {
    let response: Response;
    try {
      response = await fetcher(
        `https://api.cloudflare.com/client/v4/accounts/${env.CF_ACCOUNT_ID}/stream/live_inputs${path}`,
        {
          method,
          headers: {
            authorization: `Bearer ${env.STREAM_API_TOKEN}`,
            ...(body === undefined ? {} : { 'content-type': 'application/json' }),
          },
          ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        },
      );
    } catch {
      throw new StreamError('stream_unavailable');
    }
    if (response.status === 404) {
      await response.body?.cancel();
      return null;
    }
    if (!response.ok) {
      await response.body?.cancel();
      throw new StreamError(response.status >= 500 ? 'stream_unavailable' : 'stream_error');
    }
    const text = await response.text();
    return text ? ((JSON.parse(text) as { result?: T }).result ?? null) : null;
  }

  return {
    async createInput(name) {
      const input = await call<InputResource>('POST', '', {
        meta: { name },
        recording: { mode: 'off' },
      });
      if (!input?.uid) throw new StreamError('stream_error');
      return { uid: input.uid, publishUrl: srtUrl(input.srt), readUrl: srtUrl(input.srtPlayback) };
    },
    async deleteInput(uid) {
      await call('DELETE', `/${encodeURIComponent(uid)}`);
    },
    async connected(uid) {
      const input = await call<InputResource>('GET', `/${encodeURIComponent(uid)}`);
      if (!input) return null;
      return input.status?.current?.state === 'connected';
    },
    async listInputs() {
      const inputs = (await call<InputResource[]>('GET', '')) ?? [];
      return inputs
        .filter((input): input is InputResource & { uid: string } => Boolean(input.uid))
        .map((input) => ({
          uid: input.uid,
          name: input.meta?.name ?? null,
          createdAt: input.created ? Date.parse(input.created) : 0,
        }));
    },
  };
}
