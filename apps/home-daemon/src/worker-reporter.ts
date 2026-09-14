import type { WorkerObservation } from '@scorebug/protocol';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
const identifier = z.string().regex(/^[A-Za-z0-9_-]{1,128}$/);
const session = z.object({ sessionId: identifier });
const accepted = z.object({ accepted: z.literal(true) });
class MissingSession extends Error {}

/** Independent, bounded telemetry; failures never stop control polling or mutate intent. */
export class WorkerReporter {
  private readonly base: URL;
  private sessionId: string | undefined;
  private sequence = 0;
  private inFlight: Promise<void> | undefined;
  constructor(
    url: string,
    private readonly token: string,
    private readonly workerId: string,
    private readonly timeout = 1500,
    private readonly runId = randomUUID(),
  ) {
    try {
      this.base = new URL(url);
    } catch {
      throw new Error('invalid_worker_report_configuration');
    }
    if (
      !['http:', 'https:'].includes(this.base.protocol) ||
      this.base.username ||
      this.base.password ||
      this.base.search ||
      this.base.hash ||
      !token ||
      !identifier.safeParse(workerId).success ||
      !identifier.safeParse(runId).success ||
      !Number.isInteger(timeout) ||
      timeout < 1 ||
      timeout > 30_000
    )
      throw new Error('invalid_worker_report_configuration');
    this.base.pathname = this.base.pathname.replace(/\/$/, '') + '/';
  }
  report(observation: WorkerObservation): Promise<void> {
    if (!this.inFlight)
      this.inFlight = this.publish({ ...observation }).finally(() => {
        this.inFlight = undefined;
      });
    return this.inFlight;
  }
  private async post<T>(
    path: string,
    body: unknown,
    schema: z.ZodType<T>,
    signal: AbortSignal,
  ): Promise<T> {
    let response: Response;
    let value: unknown;
    try {
      response = await fetch(new URL(`v1/worker/${path}`, this.base), {
        method: 'POST',
        redirect: 'error',
        signal,
        headers: { authorization: `Bearer ${this.token}`, 'content-type': 'application/json' },
        body: JSON.stringify(body),
      });
      value = await response.json();
    } catch {
      throw new Error('worker_report_unavailable');
    }
    if (
      response.status === 409 &&
      z.object({ error: z.literal('worker_session_unknown') }).safeParse(value).success
    )
      throw new MissingSession();
    if (!response.ok) throw new Error('worker_report_rejected');
    const parsed = schema.safeParse(value);
    if (!parsed.success) throw new Error('invalid_worker_report_response');
    return parsed.data;
  }
  private async register(signal: AbortSignal): Promise<void> {
    this.sessionId = (
      await this.post('sessions', { workerId: this.workerId, runId: this.runId }, session, signal)
    ).sessionId;
  }
  private async publish(observation: WorkerObservation): Promise<void> {
    const signal = AbortSignal.timeout(this.timeout);
    if (!this.sessionId) await this.register(signal);
    const sequence = ++this.sequence;
    const send = () =>
      this.post(
        'observations',
        { workerId: this.workerId, sessionId: this.sessionId, sequence, observation },
        accepted,
        signal,
      );
    try {
      await send();
    } catch (error) {
      if (!(error instanceof MissingSession)) throw error;
      this.sessionId = undefined;
      await this.register(signal);
      try {
        await send();
      } catch (retry) {
        if (retry instanceof MissingSession) throw new Error('worker_report_rejected');
        throw retry;
      }
    }
  }
}
