import type { WorkerObservation } from '@scorebug/protocol';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
const identifier = z.string().regex(/^[A-Za-z0-9_-]{1,128}$/);
const session = z.object({ sessionId: identifier, timingToken: identifier.optional() });
const accepted = z.object({ accepted: z.literal(true), timingToken: identifier.optional() });
class MissingSession extends Error {}

/** Independent, bounded telemetry; failures never stop control polling or mutate intent. */
export class WorkerReporter {
  private readonly base: URL;
  private session: z.infer<typeof session> | undefined;
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
  report(sample: () => WorkerObservation | null): Promise<void> {
    if (!this.inFlight) {
      const deadline = performance.now() + this.timeout;
      const signal = AbortSignal.timeout(this.timeout);
      // Assign the shared promise before invoking a possibly reentrant supplier.
      this.inFlight = Promise.resolve()
        .then(() => this.publish(sample, signal, deadline))
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
  private async register(signal: AbortSignal): Promise<void> {
    this.session = await this.post(
      'sessions',
      { workerId: this.workerId, runId: this.runId },
      session,
      signal,
    );
  }
  private async publish(
    sample: () => WorkerObservation | null,
    signal: AbortSignal,
    deadline: number,
  ): Promise<void> {
    const checkDeadline = () => {
      // A synchronous supplier can prevent the abort timer from running on time.
      if (signal.aborted || performance.now() >= deadline)
        throw new Error('worker_report_unavailable');
    };
    for (let attempt = 0; attempt < 2; attempt++) {
      checkDeadline();
      if (!this.session) await this.register(signal);
      checkDeadline();
      const registered = this.session!;
      let observation: WorkerObservation | null;
      try {
        observation = structuredClone(sample());
      } catch {
        throw new Error('worker_report_unavailable');
      }
      checkDeadline();
      if (observation === null) return;
      if (this.sequence >= Number.MAX_SAFE_INTEGER) throw new Error('worker_report_unavailable');
      const sequence = ++this.sequence;
      try {
        const acknowledgement = await this.post(
          'observations',
          { workerId: this.workerId, ...registered, sequence, observation },
          accepted,
          signal,
        );
        checkDeadline();
        this.session = { ...registered, timingToken: acknowledgement.timingToken };
        return;
      } catch (error) {
        if (!(error instanceof MissingSession)) throw error;
        this.session = undefined;
        if (attempt === 1) throw new Error('worker_report_rejected');
      }
    }
  }
}
