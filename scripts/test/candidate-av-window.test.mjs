import assert from 'node:assert/strict';
import test from 'node:test';
import { qualifyCandidateAVTransport } from '../candidate-av-window.mjs';
import { replayCandidateTransportCost } from '../candidate-transport-cost.mjs';
const scope = {
  publishingAttemptID: '00000000-0000-4000-8000-000000000001',
  appliedProfileRevision: '1',
};
const pts = (n, d = 48000) => ({ value: String(n), timescale: d, epoch: '0', flags: 1 });
const frames = Array.from({ length: 121 }, (_, i) => ({
  sourcePTS: pts(480000 + i * 1600),
  byteCount: 600,
  isSync: i % 60 === 0,
  admittedAt: 100 + i / 30,
  dequeuedAt: 100.45 + i / 30,
}));
const expected = {
  scope,
  profile: '540p30',
  id: scope.publishingAttemptID,
  publishingGeneration: '1',
  frames,
  firstInputPTS: frames[0].sourcePTS,
  lastInputPTS: frames.at(-1).sourcePTS,
  acceptedInputCount: 121,
  startedAt: 99.99,
  endedAt: 104.46,
};
function fixture(rate = 48000) {
  const count = Math.floor((4 * rate) / 1024) + 1;
  const audio = Array.from({ length: count }, (_, i) => ({
    sourcePTS: pts(10 * rate + i * 1024, rate),
    publishingGeneration: '1',
    wasEncoded: true,
    valid: true,
    observedAt: 100 + (i * 1024) / rate,
    consumedAt: 100 + (i * 1024) / rate + 0.01,
    byteCount: 100,
    sampleRate: rate,
    channelCount: 2,
    framesPerPacket: 1024,
    audioObjectType: 2,
  }));
  const followingAudio = {
    ...audio.at(-1),
    sourcePTS: pts(10 * rate + count * 1024, rate),
    observedAt: 100 + (count * 1024) / rate,
    consumedAt: 100 + (count * 1024) / rate,
  };
  const inputs = [
    ...frames.map((f) => ({
      media: 'video',
      sourcePTS: f.sourcePTS,
      decodePTS: null,
      byteCount: f.byteCount,
      isSync: f.isSync,
      parameterSetBytes: f.isSync ? 34 : 0,
      _at: f.dequeuedAt,
    })),
    ...audio.map((f) => ({
      media: 'audio',
      sourcePTS: f.sourcePTS,
      decodePTS: null,
      byteCount: f.byteCount,
      isSync: true,
      parameterSetBytes: 0,
      _at: f.consumedAt,
    })),
  ]
    .sort((a, b) => a._at - b._at)
    .map(({ _at, ...input }) => input);
  const replay = replayCandidateTransportCost(inputs);
  const { writes, programWrites, pcrCount, ...totals } = replay;
  return {
    scope,
    profile: '540p30',
    id: expected.id,
    outcome: 'completed',
    failure: null,
    publishingGeneration: '1',
    startedAt: 100,
    closedAt: 104,
    endedAt: 104.45,
    rawInputCount: 121,
    firstRawPTS: frames[0].sourcePTS,
    lastRawPTS: frames.at(-1).sourcePTS,
    audio,
    followingAudio,
    maximumPendingCount: 1,
    maximumPendingBytes: 100,
    mux: {
      ...totals,
      inputs,
      outcome: 'completed',
      failure: null,
      firstVideoPTS: frames[0].sourcePTS,
      lastVideoPTS: frames.at(-1).sourcePTS,
      firstAudioPTS: audio[0].sourcePTS,
      lastAudioPTS: audio.at(-1).sourcePTS,
    },
  };
}
test('joins actual audio and video receipts to an independent complete mux replay', () => {
  const p = fixture(),
    r = qualifyCandidateAVTransport(p, expected);
  assert.equal(r.transportBytes, p.mux.transportBytes);
  assert.equal(r.transportMessageCount, p.mux.transportMessageCount);
  assert.equal(r.audioInputCount, 188);
  assert.equal(r.audioInputBytes, 18800);
  assert.equal(r.applicationPayloadBitsPerSecond, p.mux.transportBytes * 2);
});
const faults = {
  'missing audio': (p) => {
    p.audio = [];
  },
  'missing following witness': (p) => {
    p.followingAudio = null;
  },
  'missing mux': (p) => {
    p.mux = null;
  },
  'wrong owner': (p) => {
    p.scope = { ...scope, appliedProfileRevision: '2' };
  },
  'wrong profile': (p) => {
    p.profile = '360p30';
  },
  'wrong candidate': (p) => {
    p.id = 'old';
  },
  'wrong generation': (p) => {
    p.publishingGeneration = '2';
  },
  'failed window': (p) => {
    p.outcome = 'failed';
  },
  'failure set': (p) => {
    p.failure = 'timeout';
  },
  'failed mux': (p) => {
    p.mux.outcome = 'failed';
  },
  'raw count': (p) => {
    p.rawInputCount = 120;
  },
  'raw boundary': (p) => {
    p.lastRawPTS = pts(670400);
  },
  'timestamp ordering': (p) => {
    p.closedAt = 99;
  },
  'ended before native output': (p) => {
    p.endedAt = 104.1;
  },
  'stale audio generation': (p) => {
    p.audio[1].publishingGeneration = '2';
  },
  'passthrough audio': (p) => {
    p.audio[1].wasEncoded = false;
  },
  'invalid audio': (p) => {
    p.audio[1].valid = false;
  },
  'audio format changed': (p) => {
    p.audio[1].sampleRate = 44100;
  },
  'wrong packet frames': (p) => {
    p.audio[1].framesPerPacket = 960;
  },
  'wrong AAC profile': (p) => {
    p.audio[1].audioObjectType = 5;
  },
  'unsupported channels': (p) => {
    p.audio[1].channelCount = 7;
  },
  'oversized audio': (p) => {
    p.audio[1].byteCount = 8185;
  },
  'stale observation': (p) => {
    p.audio[1].observedAt = 99;
  },
  'consumption before observation': (p) => {
    p.audio[1].consumedAt = 100;
  },
  'late witness': (p) => {
    p.followingAudio.observedAt = 105.01;
    p.followingAudio.consumedAt = 105.01;
  },
  'witness inside video': (p) => {
    p.followingAudio.sourcePTS = p.lastRawPTS;
  },
  'missing audio packet': (p) => {
    p.audio.splice(15, 1);
  },
  'duplicate audio PTS': (p) => {
    p.audio[2].sourcePTS = p.audio[1].sourcePTS;
  },
  'video mux size changed': (p) => {
    p.mux.inputs.find((i) => i.media === 'video').byteCount++;
  },
  'audio mux size changed': (p) => {
    p.mux.inputs.find((i) => i.media === 'audio').byteCount++;
  },
  'mux total changed': (p) => {
    p.mux.transportBytes += 188;
  },
  'mux message total changed': (p) => {
    p.mux.transportMessageCount++;
  },
  'mux audio bytes changed': (p) => {
    p.mux.audioInputBytes++;
  },
  'mux boundary changed': (p) => {
    p.mux.lastAudioPTS = pts(600000);
  },
  'pending count': (p) => {
    p.maximumPendingCount = 17;
  },
  'pending bytes': (p) => {
    p.maximumPendingBytes = 131073;
  },
};
for (const [label, mutate] of Object.entries(faults))
  test(`rejects ${label}`, () => {
    const p = fixture();
    mutate(p);
    assert.throws(() => qualifyCandidateAVTransport(p, expected));
  });

test('accepts 44.1 kHz and nanosecond host-clock quantization without requiring equal timescales', () => {
  const p = fixture(44100);
  for (const a of [...p.audio, p.followingAudio]) {
    a.sourcePTS = pts((BigInt(a.sourcePTS.value) * 1000000000n) / 44100n, 1000000000);
    a.sourcePTS.flags = 3;
  }
  const audioInputs = p.mux.inputs.filter((i) => i.media === 'audio');
  for (const [i, a] of audioInputs.entries()) a.sourcePTS = p.audio[i].sourcePTS;
  p.mux.firstAudioPTS = p.audio[0].sourcePTS;
  p.mux.lastAudioPTS = p.audio.at(-1).sourcePTS;
  assert.equal(qualifyCandidateAVTransport(p, expected).audioInputCount, 173);
});

test('rejects a 101-nanosecond packet cadence discontinuity', () => {
  const p = fixture();
  const a = p.audio[3];
  a.sourcePTS = pts((BigInt(a.sourcePTS.value) * 1000000000n) / 48000n + 101n, 1000000000);
  assert.throws(() => qualifyCandidateAVTransport(p, expected), /cadence/);
});

test('rejects hidden simultaneous retention even with an in-flight observation allowance', () => {
  const p = fixture();
  for (const a of p.audio) {
    a.observedAt = 100;
    a.consumedAt = 104;
  }
  assert.throws(() => qualifyCandidateAVTransport(p, expected));
});
test('raw closure cannot move beyond the admission deadline to grant stale audio a new allowance', () => {
  const p = fixture();
  p.closedAt = 1000;
  p.endedAt = 1000.2;
  for (const a of [...p.audio, p.followingAudio]) {
    a.observedAt = 1000;
    a.consumedAt = 1000.1;
  }
  assert.throws(() => qualifyCandidateAVTransport(p, { ...expected, endedAt: 1000.2 }));
});
test('mux interleaving cannot consume audio before a preceding video was dequeued', () => {
  const p = fixture();
  p.mux.inputs.sort(
    (a, b) =>
      Number(a.sourcePTS.value) / a.sourcePTS.timescale -
      Number(b.sourcePTS.value) / b.sourcePTS.timescale,
  );
  const replay = replayCandidateTransportCost(p.mux.inputs);
  for (const key of ['transportBytes', 'transportMessageCount']) p.mux[key] = replay[key];
  assert.throws(() => qualifyCandidateAVTransport(p, expected));
});

test('following audio is selected as the end witness only after raw closure', () => {
  const p = fixture();
  p.closedAt = 104.1;
  assert.throws(() => qualifyCandidateAVTransport(p, expected));
});

test('accepts 44.1 kHz cadence quantized to the actual 24 MHz Apple Silicon host clock', () => {
  const p = fixture(44100);
  for (const a of [...p.audio, p.followingAudio]) {
    const ticks = (BigInt(a.sourcePTS.value) * 24000000n) / 44100n;
    a.sourcePTS = pts((ticks * 125n) / 3n, 1000000000);
  }
  const audioInputs = p.mux.inputs.filter((i) => i.media === 'audio');
  for (const [i, a] of audioInputs.entries()) a.sourcePTS = p.audio[i].sourcePTS;
  p.mux.firstAudioPTS = p.audio[0].sourcePTS;
  p.mux.lastAudioPTS = p.audio.at(-1).sourcePTS;
  assert.equal(qualifyCandidateAVTransport(p, expected).audioInputCount, 173);
});
test('serial video output bounds earlier muxed audio by the subsequent video dequeue', () => {
  const p = fixture();
  for (const a of p.audio.slice(20, 23)) a.consumedAt = 100.5;
  p.maximumPendingCount = 5;
  p.maximumPendingBytes = 500;
  assert.throws(() => qualifyCandidateAVTransport(p, expected));
});

test('accepts explicit equal decode and presentation times from native no-reordering video', () => {
  const p = fixture();
  for (const input of p.mux.inputs)
    if (input.media === 'video') input.decodePTS = { ...input.sourcePTS };
  const replay = replayCandidateTransportCost(p.mux.inputs);
  p.mux.transportBytes = replay.transportBytes;
  p.mux.transportMessageCount = replay.transportMessageCount;
  assert.equal(qualifyCandidateAVTransport(p, expected).transportBytes, replay.transportBytes);
});
test('rejects decode timestamps differing from presentation time in a no-reordering recipe', () => {
  const p = fixture(),
    v = p.mux.inputs.find((i) => i.media === 'video');
  v.decodePTS = { ...v.sourcePTS, value: String(BigInt(v.sourcePTS.value) - 1n) };
  const replay = replayCandidateTransportCost(p.mux.inputs);
  p.mux.transportBytes = replay.transportBytes;
  p.mux.transportMessageCount = replay.transportMessageCount;
  assert.throws(() => qualifyCandidateAVTransport(p, expected));
});

test('opening AAC may precede first raw arrival within the active measurement', () => {
  const p = fixture();
  p.audio[0].observedAt = 99.995;
  assert.doesNotThrow(() => qualifyCandidateAVTransport(p, expected));
  p.audio[0].observedAt = 99.98;
  assert.throws(() => qualifyCandidateAVTransport(p, expected));
});
