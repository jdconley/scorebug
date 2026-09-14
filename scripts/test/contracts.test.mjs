import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import assert from 'node:assert/strict';

test('Swift and TypeScript consume the same native Watch pairing fixture', () => {
  const file = 'watch-pairing-v1.json';
  const canonical = readFileSync(
    new URL(`../../packages/protocol/fixtures/${file}`, import.meta.url),
    'utf8',
  );
  const swift = readFileSync(
    new URL(
      `../../ios/Packages/ScorebugCore/Tests/ScorebugCoreTests/Fixtures/${file}`,
      import.meta.url,
    ),
    'utf8',
  );
  assert.deepEqual(JSON.parse(swift), JSON.parse(canonical));
});

test('Swift and TypeScript consume the same canonical worker status fixture', () => {
  const fixture = 'worker-status-v1.json';
  const canonical = readFileSync(
    new URL(`../../packages/protocol/fixtures/${fixture}`, import.meta.url),
    'utf8',
  );
  const swift = readFileSync(
    new URL(
      `../../ios/Packages/ScorebugCore/Tests/ScorebugCoreTests/Fixtures/${fixture}`,
      import.meta.url,
    ),
    'utf8',
  );
  assert.deepEqual(JSON.parse(swift), JSON.parse(canonical));
});

test('Swift and TypeScript consume the same canonical match contract fixture', () => {
  const canonical = readFileSync(
    new URL('../../packages/protocol/fixtures/match-v1.json', import.meta.url),
    'utf8',
  );
  const swift = readFileSync(
    new URL(
      '../../ios/Packages/ScorebugCore/Tests/ScorebugCoreTests/Fixtures/match-v1.json',
      import.meta.url,
    ),
    'utf8',
  );
  assert.deepEqual(JSON.parse(swift), JSON.parse(canonical));
});

test('Swift and TypeScript consume the same canonical media contract fixture', () => {
  const canonical = readFileSync(
    new URL('../../packages/protocol/fixtures/media-v1.json', import.meta.url),
    'utf8',
  );
  const swift = readFileSync(
    new URL(
      '../../ios/Packages/ScorebugCore/Tests/ScorebugCoreTests/Fixtures/media-v1.json',
      import.meta.url,
    ),
    'utf8',
  );
  assert.deepEqual(JSON.parse(swift), JSON.parse(canonical));
});

test('Swift and TypeScript consume the same decoded video status fixture', () => {
  const fixture = 'decoded-video-v1.json';
  const canonical = readFileSync(
    new URL(`../../packages/protocol/fixtures/${fixture}`, import.meta.url),
    'utf8',
  );
  const swift = readFileSync(
    new URL(
      `../../ios/Packages/ScorebugCore/Tests/ScorebugCoreTests/Fixtures/${fixture}`,
      import.meta.url,
    ),
    'utf8',
  );
  assert.deepEqual(JSON.parse(swift), JSON.parse(canonical));
});
