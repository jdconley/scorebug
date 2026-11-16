import { WorkerEntrypoint } from 'cloudflare:workers';
import type { Env } from './env.js';

type Props = { teamId: string | null };

/**
 * http://api.internal/ for one team's match container (an outbound intercept). It forwards
 * the worker's `/v1/worker/*` calls to that team object only, over RPC.
 */
export class WorkerApi extends WorkerEntrypoint<Env, Props> {
  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const teamId = this.ctx.props.teamId;
    if (url.hostname !== 'api.internal' || !teamId || !url.pathname.startsWith('/v1/worker/'))
      return Response.json({ error: 'forbidden' }, { status: 403 });
    const body = request.method === 'GET' ? '' : await request.text();
    const result = await this.env.TEAM.getByName(teamId).workerApi(
      request.method,
      `${url.pathname}${url.search}`,
      request.headers.get('authorization') ?? '',
      body,
    );
    return new Response(result.body, {
      status: result.status,
      headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
    });
  }
}
