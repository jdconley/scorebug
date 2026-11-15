import assert from 'node:assert/strict';
import { replayCandidateTransportCost } from './candidate-transport-cost.mjs';
const rates = [
  96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350,
];
const finite = (n) => typeof n === 'number' && Number.isFinite(n) && n >= 0 && n <= 1e12;
const integer = (n, lo, hi) => Number.isSafeInteger(n) && n >= lo && n <= hi;
function time(t) {
  assert.ok(t && typeof t.value === 'string' && /^(0|[1-9][0-9]{0,18})$/.test(t.value));
  assert.ok(
    BigInt(t.value) <= 9223372036854775807n &&
      integer(t.timescale, 1, 2147483647) &&
      t.epoch === '0' &&
      [1, 3].includes(t.flags),
  );
  return { n: BigInt(t.value), d: BigInt(t.timescale) };
}
const difference = (a, b) => ({ n: a.n * b.d - b.n * a.d, d: a.d * b.d });
const equalTime = (a, b) => assert.equal(difference(time(a), time(b)).n, 0n);
const abs = (n) => (n < 0n ? -n : n);
// Apple Silicon host ticks are 125/3 ns. Allow two tick conversions and
// nanosecond CMTime rounding, far below even one sample at 96 kHz.
const clockToleranceNanoseconds = 100n;
function cadence(a, b, rate) {
  const delta = difference(time(b), time(a));
  assert.ok(
    delta.n > 0n &&
      abs(delta.n * BigInt(rate) - 1024n * delta.d) * 1000000000n <=
        clockToleranceNanoseconds * delta.d * BigInt(rate),
    'AAC cadence is not contiguous',
  );
}
/** Fresh A/V source-window evidence; no spare capacity or decoded quality claim. */
export function qualifyCandidateAVTransport(p, expected) {
  assert.ok(p);
  for (const key of ['scope', 'profile', 'id', 'publishingGeneration'])
    assert.deepEqual(p[key], expected[key]);
  assert.ok(
    typeof p.publishingGeneration === 'string' &&
      /^[1-9][0-9]{0,19}$/.test(p.publishingGeneration) &&
      BigInt(p.publishingGeneration) <= 18446744073709551615n,
  );
  assert.equal(p.outcome, 'completed');
  assert.equal(p.failure, null);
  assert.equal(p.rawInputCount, expected.acceptedInputCount);
  equalTime(p.firstRawPTS, expected.firstInputPTS);
  equalTime(p.lastRawPTS, expected.lastInputPTS);
  for (const n of [p.startedAt, p.closedAt, p.endedAt]) assert.ok(finite(n));
  assert.ok(
    p.startedAt >= expected.startedAt &&
      p.startedAt <= expected.frames[0].admittedAt &&
      p.closedAt >= expected.frames.at(-1).admittedAt &&
      p.closedAt >= p.startedAt &&
      p.closedAt < expected.startedAt + 5 &&
      p.endedAt >= p.closedAt &&
      p.endedAt <= expected.endedAt,
  );
  assert.ok(expected.frames.every((f) => f.dequeuedAt <= p.endedAt));
  assert.ok(integer(p.maximumPendingCount, 0, 16) && integer(p.maximumPendingBytes, 0, 128 * 1024));
  assert.ok(
    p.maximumPendingBytes >= p.maximumPendingCount &&
      p.maximumPendingBytes <= p.maximumPendingCount * 8184,
  );
  assert.ok(
    Array.isArray(p.audio) && p.audio.length > 0 && p.audio.length <= 512 && p.followingAudio,
  );
  const first = time(p.firstRawPTS),
    last = time(p.lastRawPTS),
    audioFormat = p.audio[0];
  const all = [...p.audio, p.followingAudio];
  assert.ok(p.followingAudio.consumedAt >= p.closedAt, 'End witness precedes raw closure');
  const retention = [];
  let previous;
  for (const a of all) {
    assert.equal(a.publishingGeneration, p.publishingGeneration);
    assert.equal(a.wasEncoded, true);
    assert.equal(a.valid, true);
    assert.ok(
      rates.includes(a.sampleRate) &&
        integer(a.channelCount, 1, 8) &&
        a.channelCount !== 7 &&
        a.framesPerPacket === 1024 &&
        a.audioObjectType === 2,
    );
    for (const key of ['sampleRate', 'channelCount', 'framesPerPacket', 'audioObjectType'])
      assert.equal(a[key], audioFormat[key]);
    assert.ok(integer(a.byteCount, 1, 8184));
    assert.ok(
      finite(a.observedAt) &&
        finite(a.consumedAt) &&
        a.observedAt >= expected.startedAt &&
        a.consumedAt >= p.startedAt &&
        a.consumedAt >= a.observedAt &&
        a.consumedAt <= p.endedAt &&
        a.consumedAt <= p.closedAt + 1,
    );
    if (previous) {
      cadence(previous.sourcePTS, a.sourcePTS, a.sampleRate);
      assert.ok(a.observedAt >= previous.observedAt && a.consumedAt >= previous.consumedAt);
    }
    previous = a;
    if (a.consumedAt > a.observedAt) {
      retention.push({ at: a.observedAt, receipt: a, add: true });
      retention.push({ at: a.consumedAt, receipt: a, add: false });
    }
  }
  // The SRT actor delivers observations serially. At most one copied packet
  // can be in flight before the window lock. All other overlapping lifetimes
  // must fit the pending budget; subtract the largest packet conservatively.
  // This is a lower bound, not an exact replay of unexported discarded packets.
  retention.sort((a, b) => a.at - b.at || Number(a.add) - Number(b.add));
  const held = new Set();
  let heldBytes = 0;
  for (const event of retention) {
    if (event.add) {
      held.add(event.receipt);
      heldBytes += event.receipt.byteCount;
    } else {
      held.delete(event.receipt);
      heldBytes -= event.receipt.byteCount;
    }
    const largest = Math.max(0, ...[...held].map((a) => a.byteCount));
    assert.ok(
      Math.max(0, held.size - 1) <= p.maximumPendingCount &&
        heldBytes - largest <= p.maximumPendingBytes,
      'Audio retention contradicts pending limits',
    );
  }
  for (const a of p.audio) {
    const at = time(a.sourcePTS);
    assert.ok(difference(at, first).n >= 0n && difference(last, at).n >= 0n);
  }
  const opening = difference(time(p.audio[0].sourcePTS), first);
  assert.ok(
    opening.n * BigInt(audioFormat.sampleRate) * 1000000000n <=
      opening.d *
        (1024n * 1000000000n + clockToleranceNanoseconds * BigInt(audioFormat.sampleRate)),
    'Audio misses opening boundary',
  );
  assert.ok(
    difference(time(p.followingAudio.sourcePTS), last).n > 0n,
    'Missing following audio coverage',
  );
  const mux = p.mux;
  assert.ok(mux);
  assert.equal(mux.outcome, 'completed');
  assert.equal(mux.failure, null);
  const replay = replayCandidateTransportCost(mux.inputs);
  for (const key of [
    'transportBytes',
    'transportMessageCount',
    'videoInputBytes',
    'audioInputBytes',
    'videoInputCount',
    'audioInputCount',
  ])
    assert.equal(mux[key], replay[key]);
  const videos = mux.inputs.filter((i) => i.media === 'video'),
    audios = mux.inputs.filter((i) => i.media === 'audio');
  assert.equal(videos.length, expected.frames.length);
  assert.equal(audios.length, p.audio.length);
  for (const [i, v] of videos.entries()) {
    const f = expected.frames[i];
    equalTime(v.sourcePTS, f.sourcePTS);
    assert.equal(v.byteCount, f.byteCount);
    assert.equal(v.isSync, f.isSync);
    // VideoToolbox may omit DTS or explicitly repeat PTS when reordering is off.
    if (v.decodePTS !== null) equalTime(v.decodePTS, v.sourcePTS);
  }
  for (const [i, a] of audios.entries()) {
    equalTime(a.sourcePTS, p.audio[i].sourcePTS);
    assert.equal(a.byteCount, p.audio[i].byteCount);
  }
  let videoIndex = 0,
    audioIndex = 0,
    precedingVideoDequeue = 0;
  for (const input of mux.inputs) {
    if (input.media === 'video')
      precedingVideoDequeue = Math.max(
        precedingVideoDequeue,
        expected.frames[videoIndex++].dequeuedAt,
      );
    else {
      assert.ok(
        p.audio[audioIndex++].consumedAt >= precedingVideoDequeue,
        'Mux order precedes native video dequeue',
      );
      // A video can dequeue then wait for the window lock. Its serial output
      // task cannot dequeue another frame until that synchronous append returns.
      const subsequent = expected.frames[videoIndex + 1];
      if (subsequent)
        assert.ok(
          p.audio[audioIndex - 1].consumedAt <= subsequent.dequeuedAt,
          'Mux order contradicts subsequent serial video dequeue',
        );
    }
  }
  for (const [key, t] of Object.entries({
    firstVideoPTS: p.firstRawPTS,
    lastVideoPTS: p.lastRawPTS,
    firstAudioPTS: p.audio[0].sourcePTS,
    lastAudioPTS: p.audio.at(-1).sourcePTS,
  }))
    equalTime(mux[key], t);
  const span = difference(last, first),
    sourceDuration = Number(span.n) / Number(span.d);
  assert.ok(sourceDuration >= 4 && sourceDuration <= 4.25 && p.closedAt > p.startedAt);
  return {
    transportBytes: replay.transportBytes,
    transportMessageCount: replay.transportMessageCount,
    audioInputCount: replay.audioInputCount,
    audioInputBytes: replay.audioInputBytes,
    applicationPayloadBitsPerSecond:
      (replay.transportBytes * 8) / Math.min(sourceDuration, p.closedAt - p.startedAt),
  };
}
