import assert from 'node:assert/strict';
import test from 'node:test';
import { qualifyEncoderFrameDelay } from '../encoder-frame-delay-qualification.mjs';

const uuid = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const pts = (frame) => ({ value: String(7395 + frame * 2), timescale: 60, epoch: '0', flags: 1 });
function fixture() {
  const names = ['defaultIdle', 'limitedIdle', 'limitedContinuous', 'defaultRepeat'];
  return {
    formatVersion: 1,
    experiment: 'candidate-frame-delay',
    platform: 'iOS Simulator',
    workload: 'motion-blocks16',
    inputWidth: 1920,
    inputHeight: 1080,
    profile: '360p30',
    firstSourceFrame: 758,
    runs: names.map((name, index) => {
      const limited = name.startsWith('limited'),
        continuous = name === 'limitedContinuous';
      const count = continuous ? 121 : 4;
      const startedAt = 100 + index * 10;
      const firstOffer = startedAt + 0.01;
      const beforeFinishAt = firstOffer + (continuous ? 4.01 : 1.11);
      const inputs = Array.from({ length: count }, (_, i) => ({
        frame: 758 + i,
        offeredAt: firstOffer + i / 30,
        accepted: true,
      }));
      const frames = inputs.map((input, i) => {
        const completedAt = !limited
          ? beforeFinishAt + 0.002 + i * 0.001
          : i < count - 3
            ? firstOffer + (i + 3) / 30 + 0.003
            : beforeFinishAt + 0.002 + (i - count + 3) * 0.001;
        return {
          sourcePTS: pts(input.frame),
          outputPTS: pts(input.frame),
          encoderSessionID: uuid(10 + index),
          submittedAt: input.offeredAt + 0.001,
          completedAt,
          dequeuedAt: completedAt + 0.001,
          observedAt: completedAt + 0.0011,
          byteCount: i === 0 ? 8000 : 1000,
          width: 640,
          height: 360,
          isSync: i % 60 === 0,
        };
      });
      return {
        name,
        id: uuid(index + 1),
        requestedMaxFrameDelayCount: limited ? 3 : null,
        propertySetStatus: limited ? 0 : null,
        propertyCopyStatus: 0,
        propertyValue: limited ? 3 : -1,
        propertyObservedAt: firstOffer + 0.0005,
        startedAt,
        beforeFinishAt,
        endedAt: beforeFinishAt + 0.02,
        beforeFinishOutputs: limited ? count - 3 : 0,
        acceptedInputCount: count,
        outputCount: count,
        outcome: 'completed',
        failure: null,
        nativeFailure: null,
        encoderSessionID: uuid(10 + index),
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
    }),
  };
}

test('qualifies independent default controls and verified limit3 with bounded continuous cost', () => {
  const result = qualifyEncoderFrameDelay(fixture());
  assert.equal(result.experiment, 'candidate-frame-delay');
  assert.equal(result.bufferingHypothesisSupported, true);
  assert.deepEqual(
    result.cases.map((c) => c.name),
    ['defaultIdle', 'limitedIdle', 'limitedContinuous', 'defaultRepeat'],
  );
  const continuous = result.cases[2];
  assert.equal(continuous.inputCount, 121);
  assert.equal(continuous.outputCount, 121);
  assert.equal(continuous.sourceSpanSeconds, 4);
  assert.equal(continuous.maximumUnresolvedInputs, 4);
  assert.equal(continuous.payloadBytes, 128000);
  assert.equal(continuous.payloadBitsPerSecond, 256000);
  assert.match(result.interpretation, /simulator/i);
});

test('accepts equivalent exact rational PTS and baseline native readback nonnegative', () => {
  const proof = fixture();
  for (const run of proof.runs)
    for (const frame of run.frames) {
      frame.sourcePTS.value = String(BigInt(frame.sourcePTS.value) * 1000000n);
      frame.sourcePTS.timescale *= 1000000;
    }
  proof.runs[0].propertyValue = 5;
  proof.runs[3].propertyValue = 5;
  assert.equal(qualifyEncoderFrameDelay(proof).bufferingHypothesisSupported, true);
});

test('allows unchanged baseline when native property copy is unavailable', () => {
  const proof = fixture();
  for (const i of [0, 3]) {
    proof.runs[i].propertyCopyStatus = -12900;
    proof.runs[i].propertyValue = null;
  }
  const result = qualifyEncoderFrameDelay(proof);
  assert.equal(result.cases[0].propertyAvailable, false);
  assert.equal(result.cases[1].propertyAvailable, true);
});

test('allows final queued native submission during joined drain', () => {
  const proof = fixture(),
    run = proof.runs[2];
  run.frames.at(-1).submittedAt = run.beforeFinishAt + 0.001;
  assert.equal(qualifyEncoderFrameDelay(proof).bufferingHypothesisSupported, true);
});

test('offer call timestamp is not an exact native admission receipt', () => {
  const proof = fixture(),
    run = proof.runs[2];
  run.inputs[4].offeredAt = run.frames[0].dequeuedAt - 0.0001;
  assert.equal(qualifyEncoderFrameDelay(proof).cases[2].maximumUnresolvedInputs, 4);
});

for (const index of [0, 1, 3])
  test(`requires one second of actual native idle in case${index}`, () => {
    const proof = fixture(),
      run = proof.runs[index];
    run.frames.at(-1).submittedAt = run.beforeFinishAt - 0.5;
    assert.throws(() => qualifyEncoderFrameDelay(proof), /native idle/);
  });

test('rejects default control whose native submissions all occur after the drain snapshot', () => {
  const proof = fixture(),
    run = proof.runs[0];
  for (const [i, frame] of run.frames.entries())
    frame.submittedAt = run.beforeFinishAt + 0.0001 + i * 0.0001;
  assert.throws(() => qualifyEncoderFrameDelay(proof), /native idle/);
});

test('rejects finish at the SDK admission deadline even when all offers were earlier', () => {
  const proof = fixture(),
    run = proof.runs[0];
  const delta = run.startedAt + 8 - run.beforeFinishAt;
  run.beforeFinishAt += delta;
  run.endedAt += delta;
  for (const frame of run.frames)
    for (const key of ['completedAt', 'dequeuedAt', 'observedAt']) frame[key] += delta;
  assert.throws(() => qualifyEncoderFrameDelay(proof), /admission.*eight/);
});

test('allows timely admission close followed by native drain beyond eight seconds', () => {
  const proof = fixture(),
    run = proof.runs[3];
  const delta = run.startedAt + 7.9 - run.beforeFinishAt;
  run.beforeFinishAt += delta;
  run.endedAt = run.startedAt + 8.1;
  for (const frame of run.frames)
    for (const key of ['completedAt', 'dequeuedAt', 'observedAt']) frame[key] += delta + 0.1;
  assert.equal(qualifyEncoderFrameDelay(proof).bufferingHypothesisSupported, true);
});

test('reports unsupported native property set before missing failed session identity', () => {
  const proof = fixture(),
    run = proof.runs[1];
  run.propertySetStatus = -12900;
  run.propertyCopyStatus = -12900;
  run.propertyValue = null;
  run.encoderSessionID = null;
  run.outcome = 'failed';
  assert.throws(
    () => qualifyEncoderFrameDelay(proof),
    /limitedIdle.*MaxFrameDelayCount.*set.*-12900/,
  );
});

test('reports failed native property copy before missing failed session identity', () => {
  const proof = fixture(),
    run = proof.runs[1];
  run.propertyCopyStatus = -12900;
  run.propertyValue = null;
  run.encoderSessionID = null;
  assert.throws(
    () => qualifyEncoderFrameDelay(proof),
    /limitedIdle.*MaxFrameDelayCount.*copy.*-12900/,
  );
});

test('reports contradictory native property readback before missing session identity', () => {
  const proof = fixture(),
    run = proof.runs[1];
  run.propertyValue = 2;
  run.encoderSessionID = null;
  assert.throws(() => qualifyEncoderFrameDelay(proof), /MaxFrameDelayCount readback/);
});

const failures = {
  'unsupported version': (p) => {
    p.formatVersion = 2;
  },
  'wrong experiment': (p) => {
    p.experiment = 'other';
  },
  'wrong platform': (p) => {
    p.platform = 'iPhone';
  },
  'wrong source workload': (p) => {
    p.workload = 'static';
  },
  'wrong source dimensions': (p) => {
    p.inputWidth = 1280;
  },
  'wrong profile': (p) => {
    p.profile = '540p30';
  },
  'wrong first source frame': (p) => {
    p.firstSourceFrame = 757;
  },
  'missing case': (p) => {
    p.runs.pop();
  },
  'extra case': (p) => {
    p.runs.push(p.runs[0]);
  },
  'crossed case order': (p) => {
    [p.runs[0], p.runs[1]] = [p.runs[1], p.runs[0]];
  },
  'duplicate case identity': (p) => {
    p.runs[1].id = p.runs[0].id.toUpperCase();
  },
  'malformed case identity': (p) => {
    p.runs[1].id = 'case';
  },
  'reused native session': (p) => {
    p.runs[1].encoderSessionID = p.runs[0].encoderSessionID;
  },
  'missing native session': (p) => {
    p.runs[1].encoderSessionID = null;
  },
  'default property modified': (p) => {
    p.runs[0].propertySetStatus = 0;
  },
  'default request not null': (p) => {
    p.runs[0].requestedMaxFrameDelayCount = 3;
  },
  'default bad readback': (p) => {
    p.runs[0].propertyValue = -2;
  },
  'default missing readback': (p) => {
    delete p.runs[0].propertyValue;
  },
  'default success without value': (p) => {
    p.runs[0].propertyValue = null;
  },
  'default failed copy with fabricated value': (p) => {
    p.runs[0].propertyCopyStatus = -12900;
  },
  'default noninteger copy status': (p) => {
    p.runs[0].propertyCopyStatus = 0.5;
    p.runs[0].propertyValue = null;
  },
  'default missing copy status': (p) => {
    delete p.runs[0].propertyCopyStatus;
  },
  'limited wrong request': (p) => {
    p.runs[1].requestedMaxFrameDelayCount = 4;
  },
  'property set failed': (p) => {
    p.runs[1].propertySetStatus = -1;
  },
  'property copy failed': (p) => {
    p.runs[1].propertyCopyStatus = -1;
  },
  'property copy wrong value': (p) => {
    p.runs[1].propertyValue = 4;
  },
  'property observed after first submission': (p) => {
    p.runs[1].propertyObservedAt = p.runs[1].frames[0].submittedAt + 0.01;
  },
  'wrong actual recipe': (p) => {
    p.runs[1].requested.bitRate = 1;
  },
  'noncompleted outcome': (p) => {
    p.runs[1].outcome = 'cancelled';
  },
  'retained failure': (p) => {
    p.runs[1].failure = 'invalid';
  },
  'native failure': (p) => {
    p.runs[1].nativeFailure = {};
  },
  'wrong accepted count': (p) => {
    p.runs[1].acceptedInputCount = 3;
  },
  'wrong output count': (p) => {
    p.runs[1].outputCount = 3;
  },
  'missing input': (p) => {
    p.runs[1].inputs.pop();
  },
  'rejected input': (p) => {
    p.runs[1].inputs[0].accepted = false;
  },
  'wrong source input id': (p) => {
    p.runs[1].inputs[0].frame = 759;
  },
  'missing output': (p) => {
    p.runs[1].frames.pop();
  },
  'duplicate output': (p) => {
    p.runs[1].frames[1] = p.runs[1].frames[0];
  },
  'old output session': (p) => {
    p.runs[1].frames[0].encoderSessionID = p.runs[0].encoderSessionID;
  },
  'wrong output source PTS': (p) => {
    p.runs[1].frames[0].sourcePTS = pts(759);
  },
  'wrong output PTS': (p) => {
    p.runs[1].frames[0].outputPTS = pts(759);
  },
  'rounded PTS': (p) => {
    p.runs[1].frames[0].sourcePTS.flags = 3;
  },
  'nonzero PTS epoch': (p) => {
    p.runs[1].frames[0].sourcePTS.epoch = '1';
  },
  'lossy numeric PTS': (p) => {
    p.runs[1].frames[0].sourcePTS.value = 8911;
  },
  'invalid PTS scale': (p) => {
    p.runs[1].frames[0].sourcePTS.timescale = 0;
  },
  'nonfinite clock': (p) => {
    p.runs[1].frames[0].completedAt = NaN;
  },
  'negative clock': (p) => {
    p.runs[1].startedAt = -1;
  },
  'crossed run lifetimes': (p) => {
    p.runs[1].startedAt = p.runs[0].endedAt - 1;
  },
  'submission before offer': (p) => {
    p.runs[1].frames[0].submittedAt = p.runs[1].inputs[0].offeredAt - 0.001;
  },
  'callback before submission': (p) => {
    p.runs[1].frames[0].completedAt = p.runs[1].frames[0].submittedAt - 0.001;
  },
  'dequeue before callback': (p) => {
    p.runs[1].frames[0].dequeuedAt = p.runs[1].frames[0].completedAt - 0.001;
  },
  'observer before dequeue': (p) => {
    p.runs[1].frames[0].observedAt = p.runs[1].frames[0].dequeuedAt - 0.001;
  },
  'observer after joined end': (p) => {
    p.runs[1].frames[3].observedAt = p.runs[1].endedAt + 1;
  },
  'output after joined end': (p) => {
    p.runs[1].frames[3].dequeuedAt = p.runs[1].endedAt + 1;
  },
  'offer after finish starts': (p) => {
    p.runs[1].inputs[3].offeredAt = p.runs[1].beforeFinishAt + 1;
  },
  'zero bytes': (p) => {
    p.runs[1].frames[0].byteCount = 0;
  },
  'oversized compressed output': (p) => {
    p.runs[1].frames[0].byteCount = 2 * 1024 * 1024 + 1;
  },
  'fractional bytes': (p) => {
    p.runs[1].frames[0].byteCount = 1.5;
  },
  'wrong dimensions': (p) => {
    p.runs[1].frames[0].height = 240;
  },
  'missing initial keyframe': (p) => {
    p.runs[1].frames[0].isSync = false;
  },
  'nonboolean sync flag': (p) => {
    p.runs[1].frames[1].isSync = 0;
  },
  'default callback before drain': (p) => {
    const r = p.runs[0];
    r.frames[0].completedAt = r.beforeFinishAt - 0.001;
  },
  'repeat callback before drain': (p) => {
    const r = p.runs[3];
    r.frames[0].completedAt = r.beforeFinishAt - 0.001;
  },
  'default nonzero idle outputs': (p) => {
    p.runs[0].beforeFinishOutputs = 1;
  },
  'limited idle has no output': (p) => {
    p.runs[1].beforeFinishOutputs = 0;
  },
  'limited idle callback only after drain': (p) => {
    const r = p.runs[1];
    r.frames[0].completedAt = r.beforeFinishAt + 0.001;
    r.frames[0].dequeuedAt = r.beforeFinishAt + 0.002;
  },
  'impossible idle observed count': (p) => {
    p.runs[1].beforeFinishOutputs = 4;
  },
  'fractional observed count': (p) => {
    p.runs[1].beforeFinishOutputs = 0.5;
  },
  'no idle waiting interval': (p) => {
    const r = p.runs[1];
    r.beforeFinishAt = r.inputs.at(-1).offeredAt + 0.5;
  },
  'more than four unresolved native submissions': (p) => {
    const r = p.runs[2],
      cutoff = r.frames[4].submittedAt + 0.001;
    for (let i = 0; i < 4; i++) {
      r.frames[i].dequeuedAt = Math.max(r.frames[i].dequeuedAt, cutoff + i * 0.0001);
      r.frames[i].observedAt = r.frames[i].dequeuedAt + 0.0001;
    }
  },
  'continuous cadence slower than24fps': (p) => {
    const r = p.runs[2],
      origin = r.startedAt;
    for (const input of r.inputs) input.offeredAt = origin + (input.offeredAt - origin) * 1.3;
    for (const frame of r.frames)
      for (const key of ['submittedAt', 'completedAt', 'dequeuedAt', 'observedAt'])
        frame[key] = origin + (frame[key] - origin) * 1.3;
    r.beforeFinishAt = origin + (r.beforeFinishAt - origin) * 1.3;
    r.endedAt = origin + (r.endedAt - origin) * 1.3;
  },
};
for (const [name, mutate] of Object.entries(failures))
  test(`rejects ${name}`, () => {
    const proof = fixture();
    mutate(proof);
    assert.throws(() => qualifyEncoderFrameDelay(proof));
  });
