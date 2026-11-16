import type { SqlDb, SqlValue } from './sql.js';

/** The part of `DurableObjectStorage` this adapter uses, so Node can type-check it too. */
export type DurableSqlStorage = {
  sql: {
    exec(query: string, ...bindings: unknown[]): { toArray(): unknown[] };
  };
  transactionSync<T>(closure: () => T): T;
};

/** Durable Object SQLite. BEGIN/COMMIT and `PRAGMA user_version` are not allowed there, so
 * transactions go through `transactionSync` and the schema version lives in `schema_meta`. */
export function durableObjectSql(storage: DurableSqlStorage): SqlDb {
  let depth = 0;
  const rows = <T>(sql: string, params: SqlValue[]) =>
    storage.sql.exec(sql, ...params).toArray() as T[];
  return {
    exec: (sql) => void storage.sql.exec(sql).toArray(),
    get: <T>(sql: string, ...params: SqlValue[]) => rows<T>(sql, params)[0],
    all: <T>(sql: string, ...params: SqlValue[]) => rows<T>(sql, params),
    run(sql, ...params) {
      rows(sql, params);
      const [row] = rows<{ n: number }>('SELECT changes() AS n', []);
      return { changes: row?.n ?? 0 };
    },
    transaction<T>(body: () => T): T {
      if (depth > 0) return body();
      depth++;
      try {
        return storage.transactionSync(body);
      } finally {
        depth--;
      }
    },
    // The runtime owns the database's lifetime.
    close() {},
  };
}
