import { DurableObject } from 'cloudflare:workers';
import type { Env } from './env.js';

/** One per team: the team's matches, scoring and media state. */
export class TeamObject extends DurableObject<Env> {
  override async fetch(): Promise<Response> {
    return Response.json({ error: 'not_found' }, { status: 404 });
  }
}
