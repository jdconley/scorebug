/** The narrow synchronous SQL surface the stores need. Durable Object SQLite backs it in
 * production; Node's `node:sqlite` backs it in the Node tests (`test/sqlite.ts`). */
export type SqlValue = string | number | null | Uint8Array;

export interface SqlDb {
  /** Multi-statement SQL with no parameters (DDL). */
  exec(sql: string): void;
  get<T>(sql: string, ...params: SqlValue[]): T | undefined;
  all<T>(sql: string, ...params: SqlValue[]): T[];
  run(sql: string, ...params: SqlValue[]): { changes: number };
  /** Commits when `body` returns, rolls back when it throws. Nested calls run inline in the
   * outer transaction. */
  transaction<T>(body: () => T): T;
  close(): void;
}
