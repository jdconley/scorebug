import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import assert from 'node:assert/strict';

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
