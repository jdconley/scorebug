import { DurableObject } from 'cloudflare:workers';
import { Hono, type Context } from 'hono';
import { createMiddleware } from 'hono/factory';
import {
  normalizeInviteCode,
  type WorkerObservationRequest,
  type WorkerObservationResponse,
} from '@scorebug/protocol';
import type { RouteConfig } from '../config.js';
import { MatchStore } from '../matches-store.js';
import type { MediaStore } from '../media-store.js';
import { RedeemGuard } from '../rate-limit.js';
import { inviteRedeemRoutes } from '../routes/invites.js';
import { matchesRoutes, type MatchAccess } from '../routes/matches.js';
import { workerRoutes } from '../routes/media.js';
import { durableObjectSql } from '../sql-durable.js';
import { WorkerObservations } from '../worker-observations.js';
import type { Env } from './env.js';
import {
  CONTAINER_TIMEOUT_MS,
  HostedMedia,
  OUTPUT_ID,
  WORKER_ID,
  WORKER_TOKEN,
} from './hosted-media.js';
import { mediaAdapters, type MatchContainer } from './media-adapters.js';
import { routeCodeHash } from './state.js';

/** Set only by the Worker, after it checked team membership. Stripped from client requests. */
export const MEMBER_HEADER = 'x-scorebug-member';
/** Set by the Worker on every forwarded request: the team this object belongs to. */
export const TEAM_HEADER = 'x-scorebug-team';
export const MATCH_CODE_PURPOSE = 'route-code';
/** Set by the Worker from Cloudflare's client location: the broadcast title's date. */
export const TIMEZONE_HEADER = 'x-scorebug-timezone';
const MEMBER_ID = /^[A-Za-z0-9_-]{1,128}$/;

/**
 * Trusted member access. The object is reachable only through the Worker, which overwrites
 * MEMBER_HEADER with the signed-in member (or removes it on match-token routes).
 */
export function memberAccess(env: Env, team: () => string | null): MatchAccess {
  const member = (header: string | undefined) =>
    header && /^[A-Za-z0-9_-]{1,128}$/.test(header) ? `member:${header}` : undefined;
  return {
    bootstrap: createMiddleware(async (c, next) => {
      if (!member(c.req.header(MEMBER_HEADER)))
        return c.json({ error: 'unauthorized', role: 'member' }, 401);
      await next();
    }),
    issuer: (c) => member(c.req.header(MEMBER_HEADER)),
    joinLink: (code) => `${env.PUBLIC_URL}/join/${code}`,
    onInvite: {
      async issued({ inviteId, code, gameId, expiresAt }) {
        const teamId = team();
        const normalized = normalizeInviteCode(code);
        if (!teamId || !normalized) throw new Error('match code routing needs a team and a code');
        // Codes are unique per team object only; across teams an expired row may hold the
        // same hash and is replaced. A live collision fails, and the caller revokes the code.
        const result = await env.DB.prepare(
          `INSERT INTO match_codes(code_hash,invite_id,team_id,game_id,expires_at) VALUES(?,?,?,?,?)
          ON CONFLICT(code_hash) DO UPDATE SET invite_id=excluded.invite_id, team_id=excluded.team_id,
            game_id=excluded.game_id, expires_at=excluded.expires_at WHERE match_codes.expires_at<=?`,
        )
          .bind(
            routeCodeHash(env.SERVER_SECRET, MATCH_CODE_PURPOSE, normalized),
            inviteId,
            teamId,
            gameId,
            Date.parse(expiresAt),
            Date.now(),
          )
          .run();
        if (result.meta.changes === 0) throw new Error('match code already routed by another team');
      },
      async revoked({ inviteId }) {
        await env.DB.prepare('DELETE FROM match_codes WHERE invite_id=?').bind(inviteId).run();
      },
    },
  };
}

/** Worker reports, plus the idle guard's clock: fresh output resets it. */
class HostedObservations extends WorkerObservations {
  constructor(
    media: MediaStore,
    private readonly onOutput: (gameId: string) => void,
  ) {
    super(media);
  }
  override report(body: WorkerObservationRequest): WorkerObservationResponse {
    const result = super.report(body);
    if (body.observation.state === 'producing_output') this.onOutput(body.observation.gameId);
    return result;
  }
}

type Exports = Record<string, (options: { props: unknown }) => Fetcher>;

/** The object's own container (`containers` in wrangler.jsonc), if the runtime has one. */
function durableContainer(
  ctx: DurableObjectState,
  team: () => string | null,
): MatchContainer | null {
  const container = ctx.container;
  if (!container) return null;
  return {
    get running() {
      return container.running;
    },
    async start(env) {
      const exports = (ctx as unknown as { exports: Exports }).exports;
      const image = container.images.base;
      if (!image) throw new Error('container_image_missing');
      // The only intercept: the worker's control API. Stream and YouTube (both RTMPS) are
      // direct, and nothing in the container holds a credential for the team object.
      await container.interceptOutboundHttp(
        'api.internal',
        exports.WorkerApi!({ props: { teamId: team() } }),
      );
      container.start({ image, instance: 'standard-4', enableInternet: true, env });
      await container.setInactivityTimeout(CONTAINER_TIMEOUT_MS);
      ctx.waitUntil(
        container
          .monitor()
          .catch((error: unknown) => console.warn('container_exited', String(error)))
          // A crash is restarted by the next alarm; bring it forward.
          .finally(() => ctx.storage.setAlarm(Date.now() + 1000)),
      );
    },
    async destroy() {
      if (container.running) await container.destroy();
    },
    renew: (timeoutMs) => container.setInactivityTimeout(timeoutMs),
  };
}

/** One per team, named by the team ID: the team's matches, scoring and media state. */
export class TeamObject extends DurableObject<Env> {
  private readonly app: Hono;
  private readonly workerApp: Hono;
  readonly store: MatchStore;
  readonly media: HostedMedia;
  /** This object's team: its name, else what the Worker said (one object is one team). */
  private team: string | null;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.team = ctx.id.name ?? null;
    const adapters = mediaAdapters(env);
    const sql = durableObjectSql(ctx.storage);
    let media: HostedMedia | undefined;
    this.store = new MatchStore(sql, env.SERVER_SECRET, Date.now, {
      output: (gameId) => media?.output(gameId) ?? null,
    });
    const team = () => this.team;
    media = this.media = new HostedMedia({
      sql,
      store: this.store,
      env,
      adapters,
      container: adapters.container ? adapters.container(ctx, team) : durableContainer(ctx, team),
      team,
      setAlarm: (at) => void ctx.storage.setAlarm(at),
      waitUntil: (promise) => ctx.waitUntil(promise),
    });
    const hosted = this.media;
    const observations = new HostedObservations(this.store.media, (gameId) =>
      hosted.onOutput(gameId),
    );
    // One fixed worker per match container; the intercept is its authentication.
    const config: RouteConfig = {
      workerToken: WORKER_TOKEN,
      workerId: WORKER_ID,
      outputId: OUTPUT_ID,
    };
    const inner = new Hono();
    inner.route(
      '/v1/matches',
      matchesRoutes(config, this.store, memberAccess(env, team), hosted, observations),
    );
    inner.route('/v1/invites', inviteRedeemRoutes(this.store, new RedeemGuard()));
    inner.notFound((c) => c.json({ error: 'not_found' }, 404));

    const app = new Hono();
    app.post('/v1/matches/:id/media/commands', (c) => this.mediaCommand(c, inner));
    app.post('/v1/matches/:id/join', async (c) => {
      const text = await c.req.text();
      const response = await inner.fetch(rebuilt(c, text));
      if (response.status === 200 && /"role"\s*:\s*"capture"/.test(text))
        hosted.prewarm(c.req.param('id'));
      return response;
    });
    // Match reads carry the match's YouTube link next to the snapshot.
    for (const path of ['/v1/matches/:id', '/v1/matches/:id/media/status'])
      app.get(path, async (c) => withYouTube(hosted, await inner.fetch(c.req.raw)));
    app.all('*', (c) => inner.fetch(c.req.raw));
    this.app = app;

    this.workerApp = new Hono();
    this.workerApp.route('/v1/worker', workerRoutes(config, this.store, hosted, observations));
    this.workerApp.notFound((c) => c.json({ error: 'not_found' }, 404));
  }

  /**
   * Go Live and stop. A start is checked against the team channel, Stream and the service-wide live cap
   * before the store sees it (a refusal is a 409 outcome the store never records, so a retry
   * can succeed); the container follows the store's accepted outcome.
   */
  private async mediaCommand(c: Context, inner: Hono): Promise<Response> {
    const gameId = c.req.param('id') ?? '';
    const text = await c.req.text();
    const command = parseCommand(text);
    const member = MEMBER_ID.test(c.req.header(MEMBER_HEADER) ?? '');
    const type = command?.operation?.type;
    const fresh =
      member &&
      command?.gameId === gameId &&
      typeof command.commandId === 'string' &&
      this.store.get(gameId) !== undefined &&
      this.store.media.receipt(gameId, command.commandId) === undefined &&
      command.expectedGeneration === this.store.media.get(gameId).broadcast.generation;
    if (fresh && type === 'start') {
      const refusal = await this.media.prepareGoLive(gameId, c.req.header(TIMEZONE_HEADER) ?? null);
      if (refusal)
        return c.json(
          {
            commandId: command!.commandId,
            accepted: false,
            error: refusal,
            snapshot: this.store.media.get(gameId),
            youtube: this.media.youtube(gameId),
          },
          409,
        );
    }
    const response = await inner.fetch(rebuilt(c, text));
    if (
      member &&
      (type === 'start' || type === 'stop') &&
      (response.ok || response.status === 409)
    ) {
      const outcome = (await response
        .clone()
        .json()
        .catch(() => null)) as {
        accepted?: boolean;
      } | null;
      if (outcome?.accepted) {
        if (type === 'start') await this.media.started(gameId);
        else await this.media.stopped(gameId);
      } else if (fresh && type === 'start') await this.media.refused(gameId);
    }
    return withYouTube(this.media, response, gameId);
  }

  override async fetch(request: Request): Promise<Response> {
    this.team ??= request.headers.get(TEAM_HEADER);
    const response = await this.app.fetch(request);
    // An end_match (or the last set) ends the match: tear its media down now.
    this.media.checkEnded();
    return response;
  }

  /** The match container's control API, reached only through its api.internal intercept. */
  async workerApi(
    method: string,
    path: string,
    authorization: string,
    body: string,
  ): Promise<{ status: number; body: string }> {
    const request = new Request(new URL(path, 'http://api.internal'), {
      method,
      headers: { authorization, 'content-type': 'application/json' },
      ...(method === 'GET' || method === 'HEAD' ? {} : { body }),
    });
    const response = await this.workerApp.fetch(request);
    return { status: response.status, body: await response.text() };
  }

  override async alarm(): Promise<void> {
    await this.media.alarm();
  }

  /** Account deletion: every match broadcasting to these YouTube connections stops and
   * forgets its broadcast. */
  async releaseConnections(teamId: string, connectionIds: string[]): Promise<void> {
    this.team ??= teamId;
    await this.media.releaseConnections(connectionIds);
  }

  /** The team is being deleted: tear down every match's media, then drop all its storage. */
  async erase(teamId: string): Promise<void> {
    this.team ??= teamId;
    await this.media.teardownAll();
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
  }

  /** The daily sweep: guards, orphaned container, and the Stream inputs still in use. */
  async sweep(teamId: string): Promise<{ inputs: string[] }> {
    this.team ??= teamId;
    return this.media.sweep();
  }
}

type CommandShape = {
  commandId?: unknown;
  gameId?: unknown;
  expectedGeneration?: unknown;
  operation?: { type?: unknown };
};
/** Just enough to decide on side effects; the inner route validates the command. */
function parseCommand(text: string): CommandShape | null {
  try {
    const value = JSON.parse(text) as unknown;
    return value && typeof value === 'object' ? (value as CommandShape) : null;
  } catch {
    return null;
  }
}

/** The same request with its body already read. */
function rebuilt(c: Context, body: string): Request {
  return new Request(c.req.url, { method: c.req.method, headers: c.req.raw.headers, body });
}

/** Adds `youtube` (the match's broadcast link, or null) to a JSON match response. */
async function withYouTube(
  media: HostedMedia,
  response: Response,
  gameId?: string,
): Promise<Response> {
  if (!response.headers.get('content-type')?.startsWith('application/json')) return response;
  const body = (await response
    .clone()
    .json()
    .catch(() => null)) as Record<string, unknown> | null;
  if (!body || typeof body !== 'object' || 'youtube' in body) return response;
  const snapshot = body.snapshot as { id?: unknown; gameId?: unknown } | null | undefined;
  const status = body.status as { gameId?: unknown } | undefined;
  const id = [gameId, snapshot?.id, snapshot?.gameId, status?.gameId].find(
    (value): value is string => typeof value === 'string',
  );
  if (!id) return response;
  const headers = new Headers(response.headers);
  headers.delete('content-length');
  return new Response(JSON.stringify({ ...body, youtube: media.youtube(id) }), {
    status: response.status,
    headers,
  });
}
