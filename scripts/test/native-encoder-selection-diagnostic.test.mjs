import assert from 'node:assert/strict';
import test from 'node:test';
const module = await import('../native-encoder-selection-diagnostic.mjs').catch((error) => {
  if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
  return {};
});
const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  other = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
function fixture() {
  return {
    submissionOverflow: false,
    submissionCalls: [
      {
        encoderSessionID: id,
        selectionQueriedAfterPreparation: { state: 'hardware', nativeStatus: null },
      },
      {
        encoderSessionID: id,
        selectionQueriedAfterPreparation: { state: 'hardware', nativeStatus: null },
      },
      {
        encoderSessionID: other,
        selectionQueriedAfterPreparation: { state: 'readFailed', nativeStatus: -123 },
      },
    ],
  };
}
function qualify(f) {
  assert.equal(typeof module.diagnoseNativeEncoderSelection, 'function');
  return module.diagnoseNativeEncoderSelection(f);
}
test('cached selection joins by original encoder session without granting health or capacity', () => {
  const f = fixture(),
    before = structuredClone(f),
    result = qualify(f);
  assert.deepEqual(f, before);
  assert.equal(result.diagnosticOnly, true);
  assert.equal(result.measurement, 'selectionQueriedAfterPreparation');
  assert.equal(result.submissions, 3);
  assert.equal(result.sessions.length, 2);
  assert.deepEqual(
    result.sessions.map((r) => [r.encoderSessionID, r.submissions, r.selection]),
    [
      [id, 2, { state: 'hardware', nativeStatus: null }],
      [other, 1, { state: 'readFailed', nativeStatus: -123 }],
    ],
  );
  assert.deepEqual(Object.keys(result).sort(), [
    'diagnosticOnly',
    'measurement',
    'sessions',
    'submissions',
  ]);
});
for (const state of ['hardware', 'software', 'missingValue', 'invalidType', 'notQueriedOnPlatform'])
  test(`diagnostic preserves ${state} without treating it as a stream-success gate`, () => {
    const f = fixture();
    f.submissionCalls.forEach(
      (r) => (r.selectionQueriedAfterPreparation = { state, nativeStatus: null }),
    );
    assert(qualify(f).sessions.every((r) => r.selection.state === state));
  });
for (const [name, mutate] of [
  [
    'overflow',
    (f) => {
      f.submissionOverflow = true;
    },
  ],
  [
    'empty',
    (f) => {
      f.submissionCalls = [];
    },
  ],
  [
    'unbounded',
    (f) => {
      f.submissionCalls = Array.from({ length: 513 }, () => f.submissionCalls[0]);
    },
  ],
  [
    'missing selection',
    (f) => {
      delete f.submissionCalls[0].selectionQueriedAfterPreparation;
    },
  ],
  [
    'unknown state',
    (f) => {
      f.submissionCalls[0].selectionQueriedAfterPreparation.state = 'unknown';
    },
  ],
  [
    'noncanonical session',
    (f) => {
      f.submissionCalls[0].encoderSessionID = 'other';
    },
  ],
  [
    'selection changes within session',
    (f) => {
      f.submissionCalls[1].selectionQueriedAfterPreparation.state = 'software';
    },
  ],
  [
    'missing failure code',
    (f) => {
      f.submissionCalls[2].selectionQueriedAfterPreparation.nativeStatus = null;
    },
  ],
  [
    'zero failure code',
    (f) => {
      f.submissionCalls[2].selectionQueriedAfterPreparation.nativeStatus = 0;
    },
  ],
  [
    'noninteger failure code',
    (f) => {
      f.submissionCalls[2].selectionQueriedAfterPreparation.nativeStatus = -1.5;
    },
  ],
  [
    'out of range code',
    (f) => {
      f.submissionCalls[2].selectionQueriedAfterPreparation.nativeStatus = 2147483648;
    },
  ],
  [
    'code on selected result',
    (f) => {
      f.submissionCalls[0].selectionQueriedAfterPreparation.nativeStatus = -1;
    },
  ],
  [
    'unsupported metadata',
    (f) => {
      f.submissionCalls[0].selectionQueriedAfterPreparation.authorized = true;
    },
  ],
])
  test(`diagnostic rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });
