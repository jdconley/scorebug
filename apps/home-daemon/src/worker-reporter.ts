import type { WorkerObservation, WorkerOutput } from '@scorebug/protocol';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';

const identifier = z.string().regex(/^[A-Za-z0-9_-]{1,128}$/);
const session = z.object({ sessionId: identifier });
const accepted = z.object({ accepted: z.literal(true) });
class MissingSession extends Error {}

/** Posts the supervisor's state to the control plane. Failures never stop control polling. */
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
    /** The configured output profile, shown to the app with the status. */
    private readonly output?: WorkerOutput,
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

  /** At most one report in flight; concurrent callers share it. */
  report(sample: () => WorkerObservation | null): Promise<void> {
    if (!this.inFlight) {
      const signal = AbortSignal.timeout(this.timeout);
      // Assign the shared promise before invoking a possibly reentrant supplier.
      this.inFlight = Promise.resolve()
        .then(() => this.publish(sample, signal))
        .finally(() => {
          this.inFlight = undefined;
        });
    }
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
      path === 'observations' &&
      response.status === 409 &&
      z.object({ error: z.literal('worker_session_unknown') }).safeParse(value).success
    )
      throw new MissingSession();
    if (!response.ok) throw new Error('worker_report_rejected');
    const parsed = schema.safeParse(value);
    if (!parsed.success) throw new Error('invalid_worker_report_response');
    return parsed.data;
  }

  private async publish(
    sample: () => WorkerObservation | null,
    signal: AbortSignal,
  ): Promise<void> {
    // Two passes: an API restart forgets sessions, so register again once.
    for (let attempt = 0; attempt < 2; attempt++) {
      if (signal.aborted) throw new Error('worker_report_unavailable');
      try {
        this.sessionId ??= (
          await this.post(
            'sessions',
            { workerId: this.workerId, runId: this.runId },
            session,
            signal,
          )
        ).sessionId;
        let observation: WorkerObservation | null;
        try {
          observation = structuredClone(sample());
        } catch {
          throw new Error('worker_report_unavailable');
        }
        if (observation === null) return;
        if (this.output) observation.output = { ...this.output };
        if (this.sequence >= Number.MAX_SAFE_INTEGER) throw new Error('worker_report_unavailable');
        await this.post(
          'observations',
          {
            workerId: this.workerId,
            sessionId: this.sessionId,
            sequence: ++this.sequence,
            observation,
          },
          accepted,
          signal,
        );
        return;
      } catch (error) {
        if (!(error instanceof MissingSession)) throw error;
        this.sessionId = undefined;
        if (attempt === 1) throw new Error('worker_report_rejected');
      }
    }
  }
}
