import { expect, it } from 'vitest';
import { formatSrtUrl } from '../src/srt-url.js';

it('keeps ":" and "=" literal in values while escaping delimiters and percent signs', () => {
  const url = new URL('srt://[2001:db8::1]:8890/kept#fragment');
  url.searchParams.set('streamid', 'publish:scorebug-path:sbp1=a.b');
  url.searchParams.set('odd key', 'a&b#c%3A d+e');
  url.searchParams.append('pkt_size', '1316');
  const formatted = formatSrtUrl(url);
  expect(formatted).toBe(
    'srt://[2001:db8::1]:8890/kept?streamid=publish:scorebug-path:sbp1=a.b&odd%20key=a%26b%23c%253A%20d%2Be&pkt_size=1316#fragment',
  );
  const parsed = new URL(formatted);
  expect([...parsed.searchParams]).toEqual([...url.searchParams]);
  expect(parsed.host).toBe(url.host);
  expect(parsed.hash).toBe('#fragment');
  // The input URL is not mutated.
  expect(url.search).toContain('publish%3Ascorebug');
});

it('escapes "=" in keys so values still split at the first "="', () => {
  const url = new URL('srt://ingest.test:778');
  url.searchParams.set('a=b', 'c=d');
  const formatted = formatSrtUrl(url);
  expect(formatted).toBe('srt://ingest.test:778?a%3Db=c=d');
  expect(new URL(formatted).searchParams.get('a=b')).toBe('c=d');
});

it('leaves a URL without a query unchanged', () => {
  expect(formatSrtUrl(new URL('srt://ingest.test:778'))).toBe('srt://ingest.test:778');
});
