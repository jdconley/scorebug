/** Fixed-window counter. In memory: limits reset when the API restarts. */
export class RateLimiter {
  private readonly windows = new Map<string, { start: number; count: number }>();
  constructor(
    private readonly limit: number,
    private readonly windowMs: number,
    private readonly now: () => number = Date.now,
  ) {}
  /** Counts one event for `key`; false once the window's limit is used up. */
  take(key: string): boolean {
    const now = this.now();
    if (this.windows.size > 10_000)
      for (const [k, w] of this.windows) if (now - w.start >= this.windowMs) this.windows.delete(k);
    const current = this.windows.get(key);
    if (!current || now - current.start >= this.windowMs) {
      this.windows.set(key, { start: now, count: 1 });
      return true;
    }
    current.count++;
    return current.count <= this.limit;
  }
  exhausted(key: string): boolean {
    const current = this.windows.get(key);
    return !!current && this.now() - current.start < this.windowMs && current.count >= this.limit;
  }
  retryAfterSeconds(key: string): number {
    const current = this.windows.get(key);
    return current
      ? Math.max(1, Math.ceil((current.start + this.windowMs - this.now()) / 1000))
      : 1;
  }
}

/**
 * Guards an unauthenticated code redemption: a per-client attempt limit plus a
 * global limit on failed attempts, so spoofed client addresses cannot brute
 * force short codes either.
 */
export class RedeemGuard {
  readonly perClient: RateLimiter;
  readonly failures: RateLimiter;
  constructor(
    options: {
      perClient?: number;
      perClientWindowMs?: number;
      failures?: number;
      failureWindowMs?: number;
      now?: () => number;
    } = {},
  ) {
    this.perClient = new RateLimiter(
      options.perClient ?? 10,
      options.perClientWindowMs ?? 60_000,
      options.now,
    );
    this.failures = new RateLimiter(
      options.failures ?? 100,
      options.failureWindowMs ?? 10 * 60_000,
      options.now,
    );
  }
  /** Seconds to wait, or 0 when the attempt may proceed. */
  admit(client: string): number {
    if (this.failures.exhausted('*')) return this.failures.retryAfterSeconds('*');
    if (!this.perClient.take(client)) return this.perClient.retryAfterSeconds(client);
    return 0;
  }
  fail(): void {
    this.failures.take('*');
  }
}
