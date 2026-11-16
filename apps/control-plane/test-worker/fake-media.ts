import { setMediaAdaptersForTests, type MatchContainer } from '../src/worker/media-adapters.js';
import {
  StreamError,
  type ListedInput,
  type LiveInput,
  type StreamApi,
} from '../src/worker/stream.js';
import {
  watchUrl,
  YouTubeError,
  type Broadcast,
  type BroadcastRequest,
  type Channel,
  type LiveStreamInfo,
  type YouTubeApi,
} from '../src/worker/youtube.js';

type FakeBroadcast = BroadcastRequest & {
  id: string;
  boundTo: string | null;
  state: 'ready' | 'live' | 'complete' | 'deleted';
};

/** In-memory YouTube. Refresh tokens are `refresh-…` strings from FakeGoogle. */
export class FakeYouTube implements YouTubeApi {
  readonly calls: string[] = [];
  readonly revoked = new Set<string>();
  liveEnabledNow = true;
  channelInfo: Channel = {
    id: 'UC-wildcats',
    title: 'Wildcats Volleyball',
    thumbnail: 'https://yt3.example/wildcats.jpg',
  };
  readonly streams = new Map<string, LiveStreamInfo>();
  readonly broadcasts = new Map<string, FakeBroadcast>();
  private next = 0;

  private access(token: string): void {
    if (!token.startsWith('access:')) throw new YouTubeError('youtube_error');
  }
  async accessToken(refreshToken: string) {
    this.calls.push('accessToken');
    if (this.revoked.has(refreshToken)) throw new YouTubeError('invalid_grant');
    return `access:${refreshToken}`;
  }
  async channel(token: string) {
    this.access(token);
    this.calls.push('channel');
    return { ...this.channelInfo };
  }
  async liveEnabled(token: string) {
    this.access(token);
    this.calls.push('liveEnabled');
    return this.liveEnabledNow;
  }
  async createStream(token: string) {
    this.access(token);
    this.calls.push('createStream');
    const id = `stream-${++this.next}`;
    const info = { id, ingestUrl: `rtmps://a.rtmps.youtube.example/live2/key-${id}` };
    this.streams.set(id, info);
    return { ...info };
  }
  async stream(token: string, id: string) {
    this.access(token);
    this.calls.push('stream');
    const info = this.streams.get(id);
    return info ? { ...info } : null;
  }
  async createBroadcast(token: string, request: BroadcastRequest): Promise<Broadcast> {
    this.access(token);
    this.calls.push('createBroadcast');
    const id = `bcast${++this.next}`;
    this.broadcasts.set(id, { ...request, id, boundTo: null, state: 'ready' });
    return { id, watchUrl: watchUrl(id) };
  }
  async bind(token: string, broadcastId: string, streamId: string) {
    this.access(token);
    this.calls.push('bind');
    const broadcast = this.broadcasts.get(broadcastId);
    if (!broadcast || !this.streams.has(streamId)) throw new YouTubeError('not_found');
    broadcast.boundTo = streamId;
  }
  async endBroadcast(token: string, broadcastId: string) {
    this.access(token);
    this.calls.push('endBroadcast');
    const broadcast = this.broadcasts.get(broadcastId);
    if (broadcast) broadcast.state = broadcast.state === 'live' ? 'complete' : 'deleted';
  }
}

export class FakeStream implements StreamApi {
  readonly inputs = new Map<string, { name: string; connected: boolean; createdAt: number }>();
  readonly deleted: string[] = [];
  failCreate = false;
  private next = 0;

  add(name: string, createdAt = Date.now()): string {
    const uid = `input${++this.next}`;
    this.inputs.set(uid, { name, connected: false, createdAt });
    return uid;
  }
  async createInput(name: string): Promise<LiveInput> {
    if (this.failCreate) throw new StreamError('stream_unavailable');
    const uid = this.add(name);
    return {
      uid,
      publishUrl: `srt://live.cloudflare.example:778?passphrase=pub-${uid}&streamid=${uid}-publish`,
      readUrl: `rtmps://live.cloudflare.example:443/live/play-${uid}`,
    };
  }
  async deleteInput(uid: string) {
    this.inputs.delete(uid);
    this.deleted.push(uid);
  }
  async connected(uid: string) {
    return this.inputs.get(uid)?.connected ?? null;
  }
  async listInputs(): Promise<ListedInput[]> {
    return [...this.inputs].map(([uid, input]) => ({
      uid,
      name: input.name,
      createdAt: input.createdAt,
    }));
  }
}

export class FakeContainer implements MatchContainer {
  running = false;
  readonly starts: Record<string, string>[] = [];
  destroys = 0;
  async start(env: Record<string, string>) {
    this.starts.push({ ...env });
    this.running = true;
  }
  async destroy() {
    this.destroys++;
    this.running = false;
  }
  async renew() {}
}

export type Fakes = { youtube: FakeYouTube; stream: FakeStream; container: FakeContainer };
let current: Fakes = fresh();
function fresh(): Fakes {
  return { youtube: new FakeYouTube(), stream: new FakeStream(), container: new FakeContainer() };
}

/** Forwards to whichever fakes the running test installed, so a team object built in an
 * earlier test still uses this test's fakes. */
function forward<T extends object>(pick: () => T): T {
  return new Proxy({} as T, {
    get: (_, key) => {
      const target = pick() as Record<string | symbol, unknown>;
      const value = target[key];
      return typeof value === 'function' ? (value as Function).bind(target) : value;
    },
  });
}

setMediaAdaptersForTests(() => ({
  youtube: forward(() => current.youtube),
  stream: forward(() => current.stream),
  container: () => forward(() => current.container),
}));

export function resetFakes(): Fakes {
  current = fresh();
  return current;
}
