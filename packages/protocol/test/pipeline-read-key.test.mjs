import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createHash } from 'node:crypto';
import * as protocol from '../dist/index.js';
const id = '11111111-1111-4111-8111-111111111111';
test('pipeline read key input is canonical, domain-separated, and platform neutral', () => {
  assert.equal(typeof protocol.pipelineReadKeyInput, 'function');
  const input = protocol.pipelineReadKeyInput(id);
  assert.equal(input, 'scorebug-pipeline-read-v1:' + id);
  assert.equal(
    createHash('sha256').update(input, 'utf8').digest('hex'),
    '5d75f38b3e289ae59af50a3cf51905342960e21554535120e565416c63d0e4f2',
  );
  assert.equal(
    protocol.pipelineReadKeyInput('abcdefab-cdef-abcd-efab-cdefabcdefab'),
    'scorebug-pipeline-read-v1:abcdefab-cdef-abcd-efab-cdefabcdefab',
  );
});
test('invalid identity has no hash input and is never normalized', () => {
  assert.equal(typeof protocol.pipelineReadKeyInput, 'function');
  for (const value of [
    undefined,
    null,
    12,
    '',
    id + '\n',
    ' ' + id,
    id + ' ',
    id + '\0',
    id.repeat(2),
    id.replaceAll('-', ''),
    'ABCDEFAB-cdef-abcd-efab-cdefabcdefab',
    'ａ'.repeat(36),
    'g' + id.slice(1),
    id.replace('-', '_'),
  ])
    assert.equal(protocol.pipelineReadKeyInput(value), undefined, String(value));
});
