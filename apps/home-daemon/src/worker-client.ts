import { z } from 'zod';
import { renderOverlayLine } from './overlay-text.js';
import type { WorkerInput } from './supervisor.js';

const id = z.string().regex(/^[A-Za-z0-9_-]{1,128}$/);
const integer = z.number().int().min(0).max(Number.MAX_SAFE_INTEGER);
const team = z.object({
  name: z.string().min(1).max(256),
  shortName: z.string().min(1).max(64),
  color: z.string(),
});
const desired = z.enum(['running', 'stopped']);
const assignmentSchema = z.object({
  assignment: z
    .object({
      match: z.object({
        id,
        revision: integer,
        status: z.enum(['active', 'ended']),
        teams: z.object({ home: team, away: team }),
        score: z.object({
          home: integer,
          away: integer,
          set: integer.min(1),
          homeSets: integer,
          awaySets: integer,
        }),
        broadcast: z.object({ desired, generation: integer }),
      }),
      media: z.object({
        gameId: id,
        broadcast: z.object({
          desired,
          generation: integer,
          selection: z
            .object({ workerId: id, outputId: id, captureDeviceId: id, recordingId: id })
            .nullable(),
        }),
      }),
    })
    .nullable(),
});
const connectionSchema = z.object({
  connection: z
    .object({
      gameId: id,
      generation: integer,
      readUrl: z
        .string()
        .max(4096)
        .url()
        .refine((value) => new URL(value).protocol === 'srt:'),
      source: z.object({
        ready: z.boolean(),
        inboundBytes: integer,
        tracks: z.array(z.string().min(1).max(64)).max(32),
      }),
    })
    .nullable(),
});

export class WorkerClient {
  private readonly base: URL;
  constructor(
    url: string,
    private readonly token: string,
    private readonly workerId: string,
    private readonly timeoutMs = 2500,
  ) {
    try {
      this.base = new URL(url);
    } catch {
      throw new Error('invalid_worker_configuration');
    }
    if (
      !['http:', 'https:'].includes(this.base.protocol) ||
      this.base.username ||
      this.base.password ||
      this.base.search ||
      this.base.hash ||
      !token ||
      !id.safeParse(workerId).success ||
      !Number.isInteger(timeoutMs) ||
      timeoutMs < 1 ||
      timeoutMs > 30_000
    )
      throw new Error('invalid_worker_configuration');
    this.base.pathname = this.base.pathname.replace(/\/$/, '') + '/';
  }
  private async get<T>(path: string, schema: z.ZodType<T>, signal: AbortSignal): Promise<T> {
    let response: Response;
    try {
      response = await fetch(new URL(`${path}?workerId=${this.workerId}`, this.base), {
        headers: { authorization: `Bearer ${this.token}` },
        signal,
        redirect: 'error',
      });
    } catch {
      throw new Error('worker_unavailable');
    }
    if (!response.ok) {
      await response.body?.cancel();
      throw new Error(`worker_http_${response.status}`);
    }
    let body: unknown;
    try {
      body = await response.json();
    } catch {
      throw new Error('worker_unavailable');
    }
    const parsed = schema.safeParse(body);
    if (!parsed.success) throw new Error('invalid_worker_response');
    return parsed.data;
  }
  async load(): Promise<WorkerInput | null> {
    const signal = AbortSignal.timeout(this.timeoutMs);
    const initial = (await this.get('v1/worker/snapshot', assignmentSchema, signal)).assignment;
    const selected = (value: typeof initial) =>
      value &&
      value.match.status === 'active' &&
      value.match.id === value.media.gameId &&
      value.match.broadcast.desired === 'running' &&
      value.media.broadcast.desired === 'running' &&
      value.match.broadcast.generation === value.media.broadcast.generation &&
      value.media.broadcast.selection?.workerId === this.workerId;
    if (!selected(initial) || !initial) return null;
    const connection = (await this.get('v1/worker/connection', connectionSchema, signal))
      .connection;
    if (
      !connection ||
      connection.gameId !== initial.match.id ||
      connection.generation !== initial.media.broadcast.generation
    )
      return null;
    const latest = (await this.get('v1/worker/snapshot', assignmentSchema, signal)).assignment;
    if (
      !selected(latest) ||
      !latest ||
      latest.match.id !== connection.gameId ||
      latest.media.broadcast.generation !== connection.generation
    )
      return null;
    if (latest.match.revision < initial.match.revision) throw new Error('invalid_worker_response');
    return {
      gameId: latest.match.id,
      generation: connection.generation,
      scoreRevision: latest.match.revision,
      overlay: renderOverlayLine(
        latest.match.teams.home,
        latest.match.teams.away,
        latest.match.score,
      ),
      readUrl: connection.readUrl,
      sourceReady: connection.source.ready,
      outputId: latest.media.broadcast.selection!.outputId,
    };
  }
}
