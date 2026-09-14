import type { PipelineHandle, PipelineProgress } from './pipeline.js';
import { atomicWrite } from './score-file.js';
import type { WorkerObservation } from '@scorebug/protocol';

export type WorkerInput = {
  gameId: string;
  generation: number;
  scoreRevision: number;
  overlay: string;
  readUrl: string;
  sourceReady: boolean;
  outputId: string;
};
export type WorkerState = {
  state:
    | 'idle'
    | 'waiting_source'
    | 'starting'
    | 'producing_output'
    | 'stopping'
    | 'retrying'
    | 'failed'
    | 'closed';
  gameId?: string;
  generation?: number;
  reason?:
    | 'assignment_changed'
    | 'source_unavailable'
    | 'output_mismatch'
    | 'control_unavailable'
    | 'control_timeout'
    | 'output_timeout'
    | 'process_exited'
    | 'score_write_failed'
    | 'start_failed'
    | 'retry_budget'
    | 'retry_delay'
    | 'shutdown';
};
export type WorkerSupervisorOptions = {
  load: () => Promise<WorkerInput | null>;
  outputId: string;
  scoreFile: string;
  start: (input: WorkerInput, onProgress: (progress: PipelineProgress) => void) => PipelineHandle;
  writeScore?: (path: string, text: string) => Promise<void>;
  onState?: (state: WorkerState) => void;
  now?: () => number;
  controlTimeoutMs?: number;
  progressTimeoutMs?: number;
  retryWindowMs?: number;
  maxAttempts?: number;
};
type Running = {
  handle: PipelineHandle;
  input: WorkerInput;
  exit: Promise<void>;
  stopping: boolean;
  lastOutput: number;
  progress?: PipelineProgress;
};

/** One process at a time. Call tick periodically; importing this module starts no work. */
export class WorkerSupervisor {
  private readonly now: () => number;
  private readonly writeScore: (path: string, text: string) => Promise<void>;
  private readonly controlTimeoutMs: number;
  private readonly progressTimeoutMs: number;
  private readonly retryWindowMs: number;
  private readonly maxAttempts: number;
  private closed = false;
  private inFlight: Promise<void> | undefined;
  private closing?: Promise<void>;
  private active: Running | undefined;
  private timer?: ReturnType<typeof setTimeout>;
  private lastControl = -Infinity;
  private controlUnavailable = false;
  private assignment?: WorkerInput;
  private attempts: number[] = [];
  private readonly budgets = new Map<string, number[]>();
  // Retain score high-water marks for the supervisor lifetime, including assignment switches.
  private readonly scores = new Map<string, Pick<WorkerInput, 'scoreRevision' | 'overlay'>>();
  private nextAttempt = -Infinity;
  private attempt = 0;
  private lastState: WorkerState = { state: 'idle' };

  constructor(private readonly options: WorkerSupervisorOptions) {
    this.now = options.now ?? (() => performance.now());
    this.writeScore = options.writeScore ?? atomicWrite;
    this.controlTimeoutMs = options.controlTimeoutMs ?? 5000;
    this.progressTimeoutMs = options.progressTimeoutMs ?? 10000;
    this.retryWindowMs = options.retryWindowMs ?? 60000;
    this.maxAttempts = options.maxAttempts ?? 3;
    for (const value of [
      this.controlTimeoutMs,
      this.progressTimeoutMs,
      this.retryWindowMs,
      this.maxAttempts,
    ]) {
      if (!Number.isSafeInteger(value) || value <= 0)
        throw new RangeError('Supervisor limits must be positive integers');
    }
  }

  /** Coalesce callers while a load, write, or actual child exit is pending. */
  tick(): Promise<void> {
    if (this.closed) return Promise.resolve();
    if (!this.inFlight) {
      this.inFlight = this.reconcile().finally(() => {
        this.inFlight = undefined;
      });
    }
    return this.inFlight;
  }

  close(): Promise<void> {
    this.closed = true;
    clearTimeout(this.timer);
    this.closing ??= this.stop('shutdown').then(() => this.emit('closed'));
    return this.closing;
  }

  /** A copied public observation; it contains no media URL or credential. */
  observation(): WorkerObservation | null {
    const state = this.lastState;
    if (state.state === 'idle' || state.gameId === undefined || state.generation === undefined)
      return null;
    const active = this.active;
    let decodedVideo: WorkerObservation['decodedVideo'];
    try {
      const snapshot = active?.handle.snapshotDecodedVideo?.();
      if (snapshot) decodedVideo = structuredClone(snapshot);
    } catch {
      // Measurement failure is unknown evidence, never an encoder/control failure.
    }
    return {
      gameId: state.gameId,
      generation: state.generation,
      state: state.state,
      reason: state.reason ?? null,
      attempt: this.attempt,
      frame: active?.progress?.frame ?? null,
      outTimeUs: active?.progress?.outTimeUs ?? null,
      scoreRevision: active?.input.scoreRevision ?? null,
      ...(decodedVideo ? { decodedVideo } : {}),
    };
  }

  private emit(
    state: WorkerState['state'],
    reason?: WorkerState['reason'],
    input = this.assignment,
  ): void {
    this.lastState = {
      state,
      ...(input && { gameId: input.gameId, generation: input.generation }),
      ...(reason && { reason }),
    };
    try {
      this.options.onState?.({ ...this.lastState });
    } catch {
      // Observer errors must neither interrupt supervision nor expose their contents.
    }
  }

  private armWatchdog(): void {
    clearTimeout(this.timer);
    const active = this.active;
    if (!active || active.stopping || this.closed) return;
    const deadline = Math.min(
      this.lastControl + this.controlTimeoutMs,
      active.lastOutput + this.progressTimeoutMs,
    );
    this.timer = setTimeout(
      () => {
        if (this.active !== active || active.stopping || this.closed) return;
        const now = this.now();
        if (now - this.lastControl >= this.controlTimeoutMs) void this.stop('control_timeout');
        else if (now - active.lastOutput >= this.progressTimeoutMs)
          void this.stop('output_timeout');
        else this.armWatchdog();
      },
      Math.max(0, deadline - this.now()),
    );
    this.timer.unref?.();
  }

  private async stop(reason: WorkerState['reason']): Promise<void> {
    const active = this.active;
    if (!active) return;
    if (!active.stopping) {
      active.stopping = true;
      clearTimeout(this.timer);
      this.emit('stopping', reason, active.input);
      try {
        active.handle.stop();
      } catch {
        // Never assume stop means exit, including when signaling fails.
      }
    }
    await active.exit;
  }

  private acceptProgress(active: Running, progress: PipelineProgress): void {
    if (this.closed || this.active !== active || active.stopping) return;
    if (
      !Number.isSafeInteger(progress.frame) ||
      !Number.isSafeInteger(progress.outTimeUs) ||
      progress.frame <= 0 ||
      progress.outTimeUs <= 0
    )
      return;
    const previous = active.progress;
    if (
      previous &&
      (progress.frame < previous.frame ||
        progress.outTimeUs < previous.outTimeUs ||
        (progress.frame === previous.frame && progress.outTimeUs === previous.outTimeUs))
    )
      return;
    active.progress = { ...progress };
    active.lastOutput = this.now();
    if (!previous) this.emit('producing_output', undefined, active.input);
    this.armWatchdog();
  }

  private async reconcile(): Promise<void> {
    let input: WorkerInput | null;
    try {
      input = await this.options.load();
    } catch {
      if (!this.closed) {
        this.controlUnavailable = true;
        this.emit('failed', 'control_unavailable');
      }
      return;
    }
    if (this.closed) return;
    if (input && input.outputId !== this.options.outputId) {
      await this.stop('output_mismatch');
      if (!this.closed) this.emit('failed', 'output_mismatch', input);
      return;
    }
    // The load contract resolves only after the entire control snapshot is validated.
    const controlRecovered = this.controlUnavailable;
    this.controlUnavailable = false;
    this.lastControl = this.now();
    this.armWatchdog();
    if (!input) {
      await this.stop('assignment_changed');
      if (!this.closed) this.emit('idle');
      return;
    }
    const assignmentKey = JSON.stringify([input.gameId, input.generation]);
    const latestScore = this.scores.get(assignmentKey);
    if (latestScore && input.scoreRevision <= latestScore.scoreRevision) {
      input = { ...input, ...latestScore };
    } else {
      this.scores.set(assignmentKey, {
        scoreRevision: input.scoreRevision,
        overlay: input.overlay,
      });
    }
    const sameGeneration =
      this.assignment?.gameId === input.gameId && this.assignment.generation === input.generation;
    this.assignment = { ...input };
    if (!sameGeneration) {
      const now = this.now();
      for (const [key, attempts] of this.budgets) {
        if (attempts.every((at) => now - at >= this.retryWindowMs)) this.budgets.delete(key);
      }
      this.attempts = this.budgets.get(JSON.stringify([input.gameId, input.generation])) ?? [];
      this.nextAttempt = this.attempts.length
        ? this.attempts.at(-1)! + Math.min(1000, this.retryWindowMs / this.maxAttempts)
        : -Infinity;
    }
    input = this.assignment;
    const old = this.active;
    if (
      old &&
      (old.input.gameId !== input.gameId ||
        old.input.generation !== input.generation ||
        old.input.readUrl !== input.readUrl ||
        old.input.outputId !== input.outputId ||
        !input.sourceReady)
    ) {
      await this.stop(input.sourceReady ? 'assignment_changed' : 'source_unavailable');
      // A deliberate routing replacement may start immediately, but still consumes the same generation's budget.
      this.nextAttempt = -Infinity;
    } else if (old?.stopping) {
      await old.exit;
    }
    if (this.closed) return;
    if (!input.sourceReady) {
      this.emit('waiting_source', 'source_unavailable');
      return;
    }
    if (this.now() - this.lastControl >= this.controlTimeoutMs) {
      this.emit('failed', 'control_timeout');
      return;
    }
    const active = this.active;
    if (active) {
      if (controlRecovered)
        this.emit(active.progress ? 'producing_output' : 'starting', undefined, active.input);
      if (input.scoreRevision <= active.input.scoreRevision) return;
      try {
        await this.writeScore(this.options.scoreFile, input.overlay);
      } catch {
        await this.stop('score_write_failed');
        if (!this.closed) this.emit('failed', 'score_write_failed');
        return;
      }
      if (this.active === active && !active.stopping) active.input = { ...input };
      return;
    }
    const now = this.now();
    this.attempts = this.attempts.filter((at) => now - at < this.retryWindowMs);
    if (this.attempts.length >= this.maxAttempts) {
      this.emit('retrying', 'retry_budget');
      return;
    }
    if (now < this.nextAttempt) {
      this.emit('retrying', 'retry_delay');
      return;
    }
    this.attempts.push(now);
    this.budgets.set(JSON.stringify([input.gameId, input.generation]), this.attempts);
    this.nextAttempt = now + Math.min(1000, this.retryWindowMs / this.maxAttempts);
    try {
      await this.writeScore(this.options.scoreFile, input.overlay);
    } catch {
      if (!this.closed) this.emit('failed', 'score_write_failed');
      return;
    }
    if (this.closed) return;
    if (this.now() - this.lastControl >= this.controlTimeoutMs) {
      this.emit('failed', 'control_timeout');
      return;
    }
    let handle: PipelineHandle;
    let running: Running | undefined;
    let earlyProgress: PipelineProgress | undefined;
    this.attempt++;
    try {
      handle = this.options.start(input, (progress) => {
        if (running) this.acceptProgress(running, progress);
        else earlyProgress = progress;
      });
    } catch {
      this.emit('failed', 'start_failed');
      return;
    }
    running = {
      handle,
      input: { ...input },
      exit: Promise.resolve(),
      stopping: false,
      lastOutput: this.now(),
    };
    const started = running;
    this.active = started;
    started.exit = handle.waitExit().then(() => {
      if (this.active !== started) return;
      this.active = undefined;
      clearTimeout(this.timer);
      if (!started.stopping && !this.closed) this.emit('retrying', 'process_exited', started.input);
    });
    this.emit('starting', undefined, input);
    if (earlyProgress) this.acceptProgress(started, earlyProgress);
    this.armWatchdog();
  }
}
