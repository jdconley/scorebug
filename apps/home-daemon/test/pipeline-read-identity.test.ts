import { expect, it } from 'vitest';
import { identifyPipelineRead } from '../src/pipeline-read-identity.js';

const streamId = 'read:scorebug-0123456789abcdef-0123456789abcdef0123456789abcdef';
const readUrl = `srt://reader:secret@relay:8890/preserved?streamid=${streamId}&latency=200000&passphrase=private&extra=one&extra=two#fragment`;
it('adds a distinct private read ID while preserving credentials and unrelated URL components', () => {
  const first = identifyPipelineRead(readUrl);
  const second = identifyPipelineRead(readUrl);
  expect(first.pipelineReadId).toMatch(
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
  );
  expect(second.pipelineReadId).not.toBe(first.pipelineReadId);
  const parsed = new URL(first.readUrl);
  expect(parsed.searchParams.get('streamid')).toBe(`${streamId}:sbw1=${first.pipelineReadId}`);
  parsed.searchParams.set('streamid', streamId);
  const expected = new URL(readUrl);
  expected.searchParams.set('streamid', streamId);
  expect(parsed.toString()).toBe(expected.toString());
});

it.each([
  '',
  'not a URL',
  'rtsp://relay/game',
  readUrl.replace('srt:', 'http:'),
  readUrl.replace('streamid=', 'StreamID='),
  readUrl.replace('streamid=', 'streamid=read:other&streamid='),
  readUrl.replace('streamid=', '%73treamid=read:other&streamid='),
  readUrl.replace(streamId, `${streamId}:already=query`),
  readUrl.replace(streamId, streamId.toUpperCase()),
  readUrl.replace(streamId, `${streamId}\n`),
  readUrl.replace(streamId, `${streamId}%0A`),
  readUrl.replace(streamId, `${streamId}0`),
  readUrl.replace(streamId, streamId.slice(0, -1)),
  readUrl.replace(streamId, streamId.replace('read:', 'publish:')),
])('leaves unsupported read URL unchanged: %j', (unsupported) => {
  expect(identifyPipelineRead(unsupported)).toEqual({ readUrl: unsupported });
});
