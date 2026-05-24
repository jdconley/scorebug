import { mkdtempSync, readFileSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { atomicWrite, scoreFilePath } from '../src/score-file.js';

describe('atomicWrite', () => {
  it('writes the file via tmp+rename', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'scorebug-test-'));
    const target = scoreFilePath(dir);
    await atomicWrite(target, 'hello');
    expect(readFileSync(target, 'utf8')).toBe('hello');
  });

  it('overwrites cleanly on successive writes', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'scorebug-test-'));
    const target = scoreFilePath(dir);
    await atomicWrite(target, 'first');
    await atomicWrite(target, 'second');
    expect(readFileSync(target, 'utf8')).toBe('second');
  });

  it('does not leave stray tmp files after completion', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'scorebug-test-'));
    const target = scoreFilePath(dir);
    await atomicWrite(target, 'a');
    await atomicWrite(target, 'b');
    await atomicWrite(target, 'c');
    const files = readdirSync(dir);
    expect(files.filter((f) => f.endsWith('.tmp'))).toEqual([]);
  });
});
