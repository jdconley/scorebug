import { expect, it } from 'vitest';
import { splitOutputUrl } from '../src/admin.js';
import { encodeQr, renderQr } from '../src/qr.js';

it('splits a full RTMP(S) output URL into destination parts', () => {
  expect(splitOutputUrl('rtmps://a.rtmp.youtube.com/live2/abcd-efgh-ijkl')).toEqual({
    rtmpUrl: 'rtmps://a.rtmp.youtube.com/live2',
    streamKey: 'abcd-efgh-ijkl',
  });
  expect(splitOutputUrl('rtmps://live-api-s.facebook.com:443/rtmp/FB-1-0-Ab?s_bl=1&a=b')).toEqual({
    rtmpUrl: 'rtmps://live-api-s.facebook.com:443/rtmp',
    streamKey: 'FB-1-0-Ab?s_bl=1&a=b',
  });
  for (const bad of ['', 'https://x/y/key', 'rtmps://host', 'rtmps://host/app/', 'rtmp://h/a/k k'])
    expect(splitOutputUrl(bad)).toBeNull();
});

// Decoding was checked against Apple's CoreImage QR detector for versions 1-13;
// these assertions pin the structure so regressions are caught in CI.
it('encodes QR symbols with the right size and finder patterns', () => {
  const link = `scorebug://connect?server=${encodeURIComponent('https://scorebug.example.com')}&code=${'A'.repeat(24)}`;
  for (const [text, size] of [
    ['hi', 21],
    [link, 41],
    ['x'.repeat(150), 49],
    ['y'.repeat(300), 69],
  ] as const) {
    const m = encodeQr(text);
    expect(m).toHaveLength(size);
    const finder = (x0: number, y0: number) =>
      [0, 1, 2, 3, 4, 5, 6].every((i) =>
        [0, 6].every((edge) => m[y0 + edge]![x0 + i] && m[y0 + i]![x0 + edge]),
      ) && m[y0 + 3]![x0 + 3];
    expect(finder(0, 0) && finder(size - 7, 0) && finder(0, size - 7)).toBe(true);
    // Timing pattern alternates.
    for (let i = 8; i < size - 8; i++) expect(m[6]![i]).toBe(i % 2 === 0);
  }
  expect(encodeQr(link)).toEqual(encodeQr(link));
  expect(() => encodeQr('z'.repeat(3000))).toThrow('qr_too_long');
});

it('renders terminal QR codes with a quiet zone', () => {
  const plain = renderQr('hi', 'plain').split('\n');
  expect(plain).toHaveLength(Math.ceil((21 + 8) / 2));
  expect(plain[0]).toBe(' '.repeat(29));
  expect(renderQr('hi')).toContain('\x1b[0m');
});
