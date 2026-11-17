import { DatabaseSync } from 'node:sqlite';
import type { SqlDb, SqlValue } from '../src/sql.js';

/** The stores' SQL surface on `node:sqlite`, for tests. A file path lets two connections
 * share one database, as concurrent requests would. */
export function openNodeSqlite(path: string): SqlDb {
  const db = new DatabaseSync(path);
  try {
    db.exec(
      'PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;',
    );
  } catch (error) {
    db.close();
    throw error;
  }
  let depth = 0;
  let open = true;
  return {
    exec: (sql) => db.exec(sql),
    get: <T>(sql: string, ...params: SqlValue[]) => db.prepare(sql).get(...params) as T | undefined,
    all: <T>(sql: string, ...params: SqlValue[]) => db.prepare(sql).all(...params) as T[],
    run: (sql, ...params) => ({ changes: Number(db.prepare(sql).run(...params).changes) }),
    transaction<T>(body: () => T): T {
      if (depth > 0) return body();
      db.exec('BEGIN IMMEDIATE');
      depth++;
      try {
        const result = body();
        db.exec('COMMIT');
        return result;
      } catch (error) {
        db.exec('ROLLBACK');
        throw error;
      } finally {
        depth--;
      }
    },
    close() {
      if (open) {
        open = false;
        db.close();
      }
    },
  };
}
