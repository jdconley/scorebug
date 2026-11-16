import { afterEach, expect, it } from 'vitest';
import { MatchStore } from '../src/matches-store.js';
import type { SqlDb } from '../src/sql.js';
import { openNodeSqlite } from '../src/sql-node.js';

const open: SqlDb[] = [];
afterEach(() => {
  for (const db of open.splice(0)) db.close();
});
function database(): SqlDb {
  const db = openNodeSqlite(':memory:');
  open.push(db);
  db.exec('CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)');
  return db;
}

it('rolls back a failed transaction', () => {
  const db = database();
  expect(() =>
    db.transaction(() => {
      db.run('INSERT INTO t(name) VALUES(?)', 'a');
      throw new Error('x');
    }),
  ).toThrow('x');
  expect(db.all('SELECT * FROM t')).toHaveLength(0);
});

it('nested transaction joins the outer one', () => {
  const db = database();
  expect(() =>
    db.transaction(() => {
      db.transaction(() => db.run('INSERT INTO t(name) VALUES(?)', 'inner'));
      throw new Error('outer');
    }),
  ).toThrow('outer');
  expect(db.all('SELECT * FROM t')).toHaveLength(0);
});

it('commits a transaction and reports changes', () => {
  const db = database();
  const result = db.transaction(() => db.run('INSERT INTO t(name) VALUES(?),(?)', 'a', 'b'));
  expect(result.changes).toBe(2);
  expect(db.all<{ name: string }>('SELECT name FROM t ORDER BY id').map((r) => r.name)).toEqual([
    'a',
    'b',
  ]);
});

it('get returns undefined for no row', () => {
  const db = database();
  expect(db.get('SELECT * FROM t WHERE id=?', 1)).toBeUndefined();
});

it('refuses a newer schema', () => {
  const db = openNodeSqlite(':memory:');
  db.exec('CREATE TABLE schema_meta(key TEXT PRIMARY KEY, value TEXT)');
  db.run("INSERT INTO schema_meta(key,value) VALUES('version','6')");
  expect(() => new MatchStore(db, 'qa-credential-key-not-production')).toThrow(
    'unsupported_database_version',
  );
});

it('records the schema version in schema_meta', () => {
  const db = openNodeSqlite(':memory:');
  const store = new MatchStore(db, 'qa-credential-key-not-production');
  expect(db.get('SELECT value FROM schema_meta WHERE key=?', 'version')).toEqual({ value: '5' });
  store.close();
});
