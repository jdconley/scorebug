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

test('Swift and TypeScript consume identical known, unknown and legacy clock fixtures', () => {
  const file = 'decoded-video-clock-v1.json';
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

test('Swift and TypeScript share exact public worker epoch fixtures including legacy omission', () => {
  const file = 'worker-epoch-v1.json';
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
  assert.equal(swift, canonical);
  const fixture = JSON.parse(canonical);
  assert.equal(fixture.current.status.workerEpoch, fixture.stale.status.workerEpoch);
  assert.notEqual(fixture.current.status.workerEpoch, fixture.replacement.status.workerEpoch);
  assert.equal(
    fixture.current.status.observation.attempt,
    fixture.replacement.status.observation.attempt,
  );
  assert.ok(!Object.hasOwn(fixture.legacy.status, 'workerEpoch'));
});
