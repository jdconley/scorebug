import { describe, expect, it } from 'vitest';
import { realStream } from '../src/worker/stream.js';

const env = { CF_ACCOUNT_ID: 'acct', STREAM_API_TOKEN: 'token' };

function fetcher(result: unknown): typeof fetch {
  return (async () =>
    new Response(JSON.stringify({ result, success: true }), {
      headers: { 'content-type': 'application/json' },
    })) as unknown as typeof fetch;
}

describe('realStream', () => {
  it('reads the container feed from RTMPS playback, not SRT playback', async () => {
    const stream = realStream(
      env,
      fetcher({
        uid: 'abc',
        srt: { url: 'srt://live.cloudflare.com:778', streamId: 'abc', passphrase: 'pub' },
        srtPlayback: {
          url: 'srt://live.cloudflare.com:778',
          streamId: 'playabc',
          passphrase: 'play',
        },
        rtmpsPlayback: { url: 'rtmps://live.cloudflare.com:443/live/', streamKey: 'playkey' },
      }),
    );
    const input = await stream.createInput('scorebug:t:g');
    expect(input.readUrl).toBe('rtmps://live.cloudflare.com:443/live/playkey');
    expect(input.publishUrl).toMatch(
      /^srt:\/\/live\.cloudflare\.com:778\?passphrase=pub&streamid=abc$/,
    );
  });

  it('refuses an input without RTMPS playback', async () => {
    const stream = realStream(
      env,
      fetcher({
        uid: 'abc',
        srt: { url: 'srt://live.cloudflare.com:778', streamId: 'abc', passphrase: 'pub' },
      }),
    );
    await expect(stream.createInput('scorebug:t:g')).rejects.toThrow('stream_error');
  });
});
