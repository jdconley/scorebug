import assert from 'node:assert/strict';
import test from 'node:test';
import { qualifyEncoderBufferDepth } from '../encoder-buffer-depth-qualification.mjs';

const MiB = 1024 * 1024;
const uuid = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const pts = (frame) => ({ value: String(7395 + frame * 2), timescale: 60, epoch: '0', flags: 1 });
function fixture(earlyNames = []) {
  return {
    formatVersion: 1,
    experiment: 'candidate-buffer-depth',
    platform: 'iOS Simulator',
    workload: 'motion-blocks16',
    inputWidth: 1920,
    inputHeight: 1080,
    profile: '360p30',
    firstSourceFrame: 758,
    rawByteBudget: 64 * MiB,
    allocationReservation: 4 * MiB,
    runs: ['default4', 'default8', 'default16', 'default20', 'defaultRepeat4'].map(
      (name, index) => {
        const count = [4, 8, 16, 20, 4][index],
          startedAt = 100 + index * 10;
        const session = uuid(index + 11);
        const inputs = Array.from({ length: count }, (_, i) => ({
          frame: 758 + i,
          offeredAt: startedAt + 0.01 + i / 30,
          returnedAt: startedAt + 0.012 + i / 30,
          rawBytes: 3 * MiB,
          encoderSessionID: session,
          sourcePTS: pts(758 + i),
        }));
        const beforeFinishAt = inputs.at(-1).returnedAt + 1.01;
        const frames = inputs.map((input, i) => {
          const submittedAt = input.offeredAt + 0.001;
          const completedAt =
            earlyNames.includes(name) && i < count - 3
              ? inputs[i + 3].offeredAt + 0.004
              : beforeFinishAt + 0.002 + i * 0.001;
          return {
            frame: input.frame,
            sourcePTS: pts(input.frame),
            outputPTS: pts(input.frame),
            encoderSessionID: session,
            submittedAt,
            completedAt,
            dequeuedAt: completedAt + 0.001,
            byteCount: i === 0 ? 8000 : 1000,
            width: 640,
            height: 360,
            isSync: i === 0,
          };
        });
        return {
          name,
          id: uuid(index + 1),
          count,
          startedAt,
          beforeFinishAt,
          beforeFinishOutputs: frames.filter((f) => f.dequeuedAt <= beforeFinishAt).length,
          endedAt: beforeFinishAt + 0.04,
          rawBytesAllocated: count * 3 * MiB,
          errors: [],
          nativeFailure: null,
          requested: {
            width: 640,
            height: 360,
            bitRate: 600000,
            profileLevel: 'H264_High_AutoLevel',
            expectedFrameRate: 30,
            maxKeyFrameIntervalDuration: 2,
            allowFrameReordering: false,
          },
          inputs,
          frames,
        };
      },
    ),
  };
}

test('fully drained negative results remain valid diagnostics, never a qualified remedy', () => {
  const result = qualifyEncoderBufferDepth(fixture());
  assert.equal(result.experiment, 'candidate-buffer-depth');
  assert.equal(result.remedyQualified, false);
  assert.equal(result.smallestCaseWithOutputBeforeFinish, null);
  assert.deepEqual(
    result.cases.map((r) => r.name),
    ['default4', 'default8', 'default16', 'default20', 'defaultRepeat4'],
  );
  const run = result.cases[3];
  assert.equal(run.count, 20);
  assert.equal(run.inputCount, 20);
  assert.equal(run.outputCount, 20);
  assert.equal(run.totalRawBytes, 60 * MiB);
  assert.equal(run.beforeFinishOutputs, 0);
  assert.equal(run.firstOutputAfterInputCount, 20);
  assert.equal(run.peakUnresolvedInputs, 20);
  assert.equal(run.peakUnresolvedRawBytes, 60 * MiB);
  assert.equal(run.payloadBytes, 27000);
});

test('reports earliest positive case and measured startup threshold without promoting remedy', () => {
  const result = qualifyEncoderBufferDepth(fixture(['default16', 'default20']));
  assert.equal(result.smallestCaseWithOutputBeforeFinish, 'default16');
  assert.equal(result.cases[2].firstOutputAfterInputCount, 4);
  assert.equal(result.cases[2].peakUnresolvedInputs, 4);
  assert.equal(result.cases[2].peakUnresolvedRawBytes, 12 * MiB);
  assert.equal(result.cases[2].beforeFinishOutputs, 13);
  assert.equal(result.remedyQualified, false);
});

test('smallest positive case is chosen by input count including the repeated control', () => {
  assert.equal(
    qualifyEncoderBufferDepth(fixture(['default16', 'defaultRepeat4']))
      .smallestCaseWithOutputBeforeFinish,
    'defaultRepeat4',
  );
});

test('rejects compressed pacing even when synchronous appends do not overlap', () => {
  const proof = fixture(),
    run = proof.runs[0];
  run.inputs[1].offeredAt = run.inputs[0].returnedAt + 0.001;
  assert.throws(() => qualifyEncoderBufferDepth(proof), /pacing/);
});

test('minimum pacing accepts submicrosecond floating clock precision', () => {
  const proof = fixture(),
    run = proof.runs[0];
  run.inputs[1].offeredAt = run.inputs[0].returnedAt + 1 / 60 - 0.5e-6;
  assert.equal(qualifyEncoderBufferDepth(proof).remedyQualified, false);
});

test('native callback may complete before synchronous append returns', () => {
  const proof = fixture(),
    run = proof.runs[0];
  run.frames[0].completedAt = run.frames[0].submittedAt + 0.0001;
  run.frames[0].dequeuedAt = run.frames[0].completedAt + 0.0001;
  run.beforeFinishOutputs = 1;
  assert.equal(qualifyEncoderBufferDepth(proof).cases[0].firstOutputAfterInputCount, 1);
});

test('computes weighted chronological occupancy with releases first at equal times', () => {
  const proof = fixture(['default8']),
    run = proof.runs[1];
  run.frames[0].dequeuedAt = run.frames[4].submittedAt;
  run.inputs[0].rawBytes = 4 * MiB;
  run.rawBytesAllocated += MiB;
  const result = qualifyEncoderBufferDepth(proof).cases[1];
  assert.equal(result.peakUnresolvedInputs, 4);
  assert.equal(result.peakUnresolvedRawBytes, 13 * MiB);
});

test('instantaneous callback and dequeue have an empty unresolved interval', () => {
  const proof = fixture(),
    run = proof.runs[0];
  run.frames[0].completedAt = run.frames[0].submittedAt;
  run.frames[0].dequeuedAt = run.frames[0].submittedAt;
  run.beforeFinishOutputs = 1;
  const result = qualifyEncoderBufferDepth(proof).cases[0];
  assert.equal(result.firstOutputAfterInputCount, 1);
  assert.equal(result.peakUnresolvedInputs, 3);
  assert.equal(result.peakUnresolvedRawBytes, 9 * MiB);
});

test('equivalent rational PTS remain exact without converting Int64 through Number', () => {
  const proof = fixture();
  for (const run of proof.runs)
    for (const frame of run.frames) {
      frame.outputPTS.value = String(BigInt(frame.outputPTS.value) * 1000000n);
      frame.outputPTS.timescale *= 1000000;
    }
  assert.equal(qualifyEncoderBufferDepth(proof).remedyQualified, false);
});

test('admission may close on time and native completion may join after eight seconds', () => {
  const proof = fixture(),
    run = proof.runs[4];
  const delta = run.startedAt + 7.9 - run.beforeFinishAt;
  run.beforeFinishAt += delta;
  run.endedAt = run.startedAt + 8.1;
  for (const frame of run.frames)
    for (const key of ['completedAt', 'dequeuedAt']) frame[key] += delta + 0.1;
  assert.equal(qualifyEncoderBufferDepth(proof).remedyQualified, false);
});

const failures = {
  'wrong version': (p) => {
    p.formatVersion = 2;
  },
  'wrong experiment': (p) => {
    p.experiment = 'other';
  },
  'wrong platform': (p) => {
    p.platform = 'iPhone';
  },
  'wrong workload': (p) => {
    p.workload = 'static';
  },
  'wrong input size': (p) => {
    p.inputHeight = 720;
  },
  'wrong profile': (p) => {
    p.profile = '540p30';
  },
  'wrong first source frame': (p) => {
    p.firstSourceFrame = 0;
  },
  'changed raw budget': (p) => {
    p.rawByteBudget += 1;
  },
  'changed allocation reservation': (p) => {
    p.allocationReservation -= 1;
  },
  'missing run': (p) => {
    p.runs.pop();
  },
  'extra run': (p) => {
    p.runs.push(p.runs[0]);
  },
  'wrong run order': (p) => {
    [p.runs[0], p.runs[1]] = [p.runs[1], p.runs[0]];
  },
  'wrong requested count': (p) => {
    p.runs[0].count = 8;
  },
  'duplicate run identity': (p) => {
    p.runs[1].id = p.runs[0].id.toUpperCase();
  },
  'malformed identity': (p) => {
    p.runs[1].id = null;
  },
  'stale native session': (p) => {
    const r = p.runs[1],
      session = p.runs[0].inputs[0].encoderSessionID;
    for (const i of r.inputs) i.encoderSessionID = session;
    for (const f of r.frames) f.encoderSessionID = session;
  },
  'mixed input sessions': (p) => {
    p.runs[0].inputs[1].encoderSessionID = uuid(99);
  },
  'output from another session': (p) => {
    p.runs[0].frames[0].encoderSessionID = uuid(99);
  },
  'malformed native session': (p) => {
    p.runs[0].inputs[0].encoderSessionID = 'native';
  },
  'wrong requested recipe': (p) => {
    p.runs[0].requested.allowFrameReordering = true;
  },
  'native failure': (p) => {
    p.runs[0].nativeFailure = 'failed';
  },
  'missing native failure field': (p) => {
    delete p.runs[0].nativeFailure;
  },
  'retained error': (p) => {
    p.runs[0].errors = ['failed'];
  },
  'malformed errors': (p) => {
    p.runs[0].errors = null;
  },
  'incomplete input': (p) => {
    p.runs[0].inputs.pop();
  },
  'incomplete output': (p) => {
    p.runs[0].frames.pop();
  },
  'extra output': (p) => {
    p.runs[0].frames.push(p.runs[0].frames[0]);
  },
  'duplicate source input': (p) => {
    p.runs[0].inputs[1] = p.runs[0].inputs[0];
  },
  'duplicate native output': (p) => {
    p.runs[0].frames[1] = p.runs[0].frames[0];
  },
  'wrong output frame ID': (p) => {
    p.runs[0].frames[0].frame = 759;
  },
  'wrong input PTS': (p) => {
    p.runs[0].inputs[0].sourcePTS = pts(759);
  },
  'wrong callback source PTS': (p) => {
    p.runs[0].frames[0].sourcePTS = pts(759);
  },
  'wrong output PTS': (p) => {
    p.runs[0].frames[0].outputPTS = pts(759);
  },
  'lossy numeric PTS': (p) => {
    p.runs[0].frames[0].sourcePTS.value = 8911;
  },
  'rounded PTS': (p) => {
    p.runs[0].frames[0].sourcePTS.flags = 3;
  },
  'nonzero epoch': (p) => {
    p.runs[0].frames[0].sourcePTS.epoch = '1';
  },
  'invalid timescale': (p) => {
    p.runs[0].frames[0].sourcePTS.timescale = 0;
  },
  'wrong actual dimensions': (p) => {
    p.runs[0].frames[0].width = 320;
  },
  'missing first keyframe': (p) => {
    p.runs[0].frames[0].isSync = false;
  },
  'nonboolean sync flag': (p) => {
    p.runs[0].frames[1].isSync = 0;
  },
  'zero output bytes': (p) => {
    p.runs[0].frames[0].byteCount = 0;
  },
  'oversized output': (p) => {
    p.runs[0].frames[0].byteCount = 2 * MiB + 1;
  },
  'fractional output bytes': (p) => {
    p.runs[0].frames[0].byteCount = 1.5;
  },
  'zero raw bytes': (p) => {
    p.runs[0].inputs[0].rawBytes = 0;
  },
  'oversized raw input': (p) => {
    p.runs[0].inputs[0].rawBytes = 4 * MiB + 1;
  },
  'fractional raw bytes': (p) => {
    p.runs[0].inputs[0].rawBytes = 1.5;
  },
  'false cumulative raw accounting': (p) => {
    p.runs[0].rawBytesAllocated -= 1;
  },
  'allocation reservation exceeds remaining cumulative budget': (p) => {
    const r = p.runs[3];
    for (let i = 0; i < 19; i++) r.inputs[i].rawBytes = Math.floor((62 * MiB) / 19);
    r.inputs[19].rawBytes = MiB;
    r.rawBytesAllocated = r.inputs.reduce((s, i) => s + i.rawBytes, 0);
  },
  'raw budget exceeded': (p) => {
    const r = p.runs[3];
    for (const i of r.inputs) i.rawBytes = 4 * MiB;
    r.rawBytesAllocated = 80 * MiB;
  },
  'nonfinite clock': (p) => {
    p.runs[0].startedAt = NaN;
  },
  'negative clock': (p) => {
    p.runs[0].inputs[0].offeredAt = -1;
  },
  'overlapping cases': (p) => {
    p.runs[1].startedAt = p.runs[0].endedAt - 1;
  },
  'offer before start': (p) => {
    p.runs[0].inputs[0].offeredAt = p.runs[0].startedAt - 0.001;
  },
  'submission before offer': (p) => {
    p.runs[0].frames[0].submittedAt = p.runs[0].inputs[0].offeredAt - 0.001;
  },
  'append returns before submission': (p) => {
    p.runs[0].inputs[0].returnedAt = p.runs[0].frames[0].submittedAt - 0.001;
  },
  'next append overlaps prior append': (p) => {
    p.runs[0].inputs[1].offeredAt = p.runs[0].inputs[0].returnedAt - 0.001;
  },
  'append returns after snapshot': (p) => {
    p.runs[0].inputs[3].returnedAt = p.runs[0].beforeFinishAt + 0.001;
  },
  'callback before submission': (p) => {
    p.runs[0].frames[0].completedAt = p.runs[0].frames[0].submittedAt - 0.001;
  },
  'dequeue before callback': (p) => {
    p.runs[0].frames[0].dequeuedAt = p.runs[0].frames[0].completedAt - 0.001;
  },
  'dequeue after joined end': (p) => {
    p.runs[0].frames[0].dequeuedAt = p.runs[0].endedAt + 1;
  },
  'false snapshot count': (p) => {
    p.runs[0].beforeFinishOutputs = 1;
  },
  'fractional snapshot count': (p) => {
    p.runs[0].beforeFinishOutputs = 0.5;
  },
  'short native idle': (p) => {
    p.runs[0].inputs[3].returnedAt = p.runs[0].beforeFinishAt - 0.9;
  },
  'expired SDK admission closure': (p) => {
    const r = p.runs[0],
      delta = r.startedAt + 8 - r.beforeFinishAt;
    r.beforeFinishAt += delta;
    r.endedAt += delta;
    for (const f of r.frames) for (const k of ['completedAt', 'dequeuedAt']) f[k] += delta;
  },
};
for (const [name, mutate] of Object.entries(failures))
  test(`rejects ${name}`, () => {
    const proof = fixture();
    mutate(proof);
    assert.throws(() => qualifyEncoderBufferDepth(proof));
  });
