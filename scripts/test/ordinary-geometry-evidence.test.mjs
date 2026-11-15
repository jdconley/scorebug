import test from 'node:test';
import assert from 'node:assert/strict';
import { ordinary720GeometryFixture } from './fixtures/ordinary720-evidence.mjs';
const module = await import('../ordinary-geometry-evidence.mjs').catch(() => ({}));
const qualify = (f) => {
  assert.equal(typeof module.qualifyOrdinary720GeometryEvidence, 'function');
  return module.qualifyOrdinary720GeometryEvidence(f);
};
test('joins ten native windows to one complete decoded geometry lifetime by opaque read key', () => {
  const f = ordinary720GeometryFixture(),
    result = qualify(f);
  assert.equal(result.geometryQualified, true);
  assert.equal(result.nativePhaseOrderingQualified, true);
  assert.equal(result.mediaQualified, false);
  assert.equal(result.transportQualified, false);
  assert.equal(result.phases.length, 10);
  assert.equal(result.pipelineOrdinal, 7);
  assert(result.phases.filter((p) => p.height === 720).length === 4);
});
for (const [name, mutate] of [
  [
    'missing720',
    (f) => {
      for (const r of f.workerRows)
        if (r.height === 720) {
          r.width = 640;
          r.height = 360;
        }
    },
  ],
  [
    'partial geometry',
    (f) => {
      f.workerRows.splice(2, 1);
    },
  ],
  [
    'duplicate index',
    (f) => {
      f.workerRows[1].runIndex = 0;
    },
  ],
  [
    'duplicate terminal',
    (f) => {
      f.workerRows.push(structuredClone(f.workerRows.at(-1)));
    },
  ],
  [
    'wrong key terminal',
    (f) => {
      f.workerRows.at(-1).pipelineReadKey = 'c'.repeat(64);
    },
  ],
  [
    'wrong game terminal',
    (f) => {
      f.workerRows.at(-1).gameId = 'other';
    },
  ],
  [
    'wrong generation',
    (f) => {
      f.expectedGeneration = 3;
    },
  ],
  [
    'attempt used as ordinal',
    (f) => {
      f.workerRows.at(-1).pipelineOrdinal = 1;
    },
  ],
  [
    'mismatched header',
    (f) => {
      f.workerRows[2].observedFrames++;
    },
  ],
  [
    'unended',
    (f) => {
      f.workerRows[2].ended = false;
    },
  ],
  [
    'invalid parser',
    (f) => {
      f.workerRows[2].invalidReason = 'numeric';
    },
  ],
  [
    'dimension',
    (f) => {
      f.workerRows[2].width = 1279;
    },
  ],
  [
    'ordinal gap',
    (f) => {
      f.workerRows[2].firstOrdinal++;
    },
  ],
  [
    'PTS rewind',
    (f) => {
      f.workerRows[2].firstPTS = f.workerRows[1].lastPTS;
    },
  ],
  [
    'counts',
    (f) => {
      f.workerRows[2].frames++;
    },
  ],
  [
    'lifetime mismatch',
    (f) => {
      f.workerRows.at(-1).decodedVideo.acceptedFrames--;
    },
  ],
  [
    'terminal missing exit',
    (f) => {
      f.workerRows.at(-1).encoderExit = null;
    },
  ],
  [
    'drain timed out',
    (f) => {
      f.workerRows.at(-1).diagnostics.drainTimedOut = true;
    },
  ],
  [
    'missing drain',
    (f) => {
      delete f.workerRows.at(-1).diagnostics;
    },
  ],
  [
    'no telemetry EOF',
    (f) => {
      f.workerRows.at(-1).telemetryEOF = false;
    },
  ],
  [
    'missing key',
    (f) => {
      delete f.native.samples[3].diagnostic.policyPipelineReadKey;
    },
  ],
  [
    'wrong native key',
    (f) => {
      f.native.samples[3].diagnostic.policyPipelineReadKey = 'c'.repeat(64);
    },
  ],
  [
    'unsafe PTS',
    (f) => {
      f.workerRows[2].lastPTS = 9007199254740992;
    },
  ],
  [
    'first endpoint outside',
    (f) => {
      f.native.samples[3].diagnostic.policyDecodedFirstPTS = String(92 * 90000);
    },
  ],
  [
    'previous not exclusive',
    (f) => {
      f.native.samples[3].diagnostic.policyDecodedPreviousPTS =
        f.native.samples[3].diagnostic.policyDecodedFirstPTS;
    },
  ],
  [
    'included previous run',
    (f) => {
      f.native.samples[3].diagnostic.policyDecodedPreviousPTS = '0';
    },
  ],
  [
    'window count',
    (f) => {
      f.native.samples[3].diagnostic.policyDecodedFrameCount = '9000';
    },
  ],
  [
    '720 sandwich',
    (f) => {
      const r = f.workerRows[2],
        start = r.firstOrdinal,
        end = r.lastOrdinal;
      const segments = [
        [start, 97 * 30, 1280, 720],
        [97 * 30 + 1, 98 * 30, 426, 240],
        [98 * 30 + 1, end, 1280, 720],
      ].map(([a, b, width, height]) => ({
        ...r,
        firstOrdinal: a,
        lastOrdinal: b,
        firstPTS: a * 3000,
        lastPTS: b * 3000,
        frames: b - a + 1,
        width,
        height,
      }));
      f.workerRows.splice(2, 1, ...segments);
      f.workerRows
        .filter((r) => r.msg === 'worker_decoded_geometry')
        .forEach((r, i) => {
          r.runIndex = i;
          r.runCount = 8;
        });
    },
  ],
  [
    'oversized record',
    (f) => {
      f.workerRows[2].padding = 'x'.repeat(4096);
    },
  ],
])
  test(`geometry rejects ${name}`, () => {
    const f = ordinary720GeometryFixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });

test('signed safe transport coordinates and unrelated log data never become geometry authority', () => {
  const f = ordinary720GeometryFixture(),
    shift = -30000000;
  for (const r of f.workerRows) {
    if (r.msg === 'worker_decoded_geometry') {
      r.firstPTS += shift;
      r.lastPTS += shift;
      r.privateText = 'srt://secret@host';
    } else
      for (const field of ['firstPTS', 'lastPTS', 'highestPTS']) r.decodedVideo[field] += shift;
  }
  for (const sample of f.native.samples)
    for (const field of [
      'policyDecodedPreviousPTS',
      'policyDecodedFirstPTS',
      'policyDecodedLastPTS',
    ])
      sample.diagnostic[field] = String(Number(sample.diagnostic[field]) + shift);
  for (const record of f.audit.records)
    for (const field of [
      'policyDecodedPreviousPTS',
      'policyDecodedFirstPTS',
      'policyDecodedLastPTS',
    ])
      record.diagnostic[field] = String(Number(record.diagnostic[field]) + shift);
  f.workerRows.push({ msg: 'unrelated', pipelineReadKey: 'other', privateText: 'secret' });
  const result = qualify(f);
  assert.equal(result.geometryQualified, true);
  assert(!JSON.stringify(result).includes('secret'));
  assert(BigInt(result.phases[0].firstPTS) < 0n);
});

for (const [name, sampleIndex, anchor] of [
  ['first run', 0, '-1'],
  ['later run', 1, String(48 * 90000 - 3000)],
])
  test(`geometry rejects omitted first boundary frame in ${name}`, () => {
    const f = ordinary720GeometryFixture();
    f.native.samples[sampleIndex].diagnostic.policyDecodedPreviousPTS = anchor;
    assert.throws(() => qualify(f));
  });
