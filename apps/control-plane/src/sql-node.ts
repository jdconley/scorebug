import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import type { SqlDb, SqlValue } from './sql.js';

/** `node:sqlite` with the self-hosted server's durability PRAGMAs. */
export function openNodeSqlite(path: string): SqlDb {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
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
