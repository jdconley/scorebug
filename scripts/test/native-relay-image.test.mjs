import assert from 'node:assert/strict';
import test from 'node:test';
import { nativeRelayImageTag } from '../native-relay-image.mjs';
test('selects isolated relay versions for legacy and staged publications', () => {
  assert.equal(nativeRelayImageTag({}), 'bluenviron/mediamtx:1.21.0');
  assert.equal(nativeRelayImageTag({ requirePublication: true }), 'scorebug/ingest:recovery-v1');
  assert.equal(
    nativeRelayImageTag({ requirePublication: true, requireReceiverProbe: true }),
    'scorebug/ingest:receiver-probe-v1',
  );
  assert.equal(
    nativeRelayImageTag({
      requirePublication: true,
      requireReceiverProbe: true,
      stagedReceiverProbe: true,
    }),
    'scorebug/ingest:staged-probe-v2',
  );
});
for (const options of [
  { requireReceiverProbe: true },
  { stagedReceiverProbe: true },
  { requirePublication: true, stagedReceiverProbe: true },
  { requireReceiverProbe: true, stagedReceiverProbe: true },
  { requirePublication: 1 },
  { requireReceiverProbe: 'true' },
  { stagedReceiverProbe: null },
])
  test(`rejects invalid relay selector ${JSON.stringify(options)}`, () => {
    assert.throws(() => nativeRelayImageTag(options));
  });

const repeated = {
  requirePublication: true,
  requireReceiverProbe: true,
  stagedReceiverProbe: true,
  candidateHeadroom: true,
  repeatedReceiverProbe: true,
};
test('repeated receiver probes use the fresh campaign-v3 image without changing legacy tags', () => {
  assert.equal(nativeRelayImageTag(repeated), 'scorebug/ingest:campaign-probe-v3');
  assert.equal(
    nativeRelayImageTag({ ...repeated, repeatedReceiverProbe: false }),
    'scorebug/ingest:staged-probe-hd-v2',
  );
});
for (const key of [
  'requirePublication',
  'requireReceiverProbe',
  'stagedReceiverProbe',
  'candidateHeadroom',
]) {
  test(`repeated relay requires ${key}`, () => {
    assert.throws(() => nativeRelayImageTag({ ...repeated, [key]: false }));
  });
}
test('repeated relay selection requires an actual boolean', () => {
  for (const value of [null, 0, 1, 'true', 'false'])
    assert.throws(() => nativeRelayImageTag({ ...repeated, repeatedReceiverProbe: value }));
});
const owned = { ...repeated, repeatedReceiverProbe: false, ownedReceiverProbe: true };
test('owned retries require campaign-v3 even with a staged three-rate measurement', () => {
  assert.equal(nativeRelayImageTag(owned), 'scorebug/ingest:campaign-probe-v3');
  assert.equal(
    nativeRelayImageTag({ ...owned, ownedReceiverProbe: false }),
    'scorebug/ingest:staged-probe-hd-v2',
  );
});
test('owned relay selection requires its complete probe route and a boolean', () => {
  for (const key of [
    'requirePublication',
    'requireReceiverProbe',
    'stagedReceiverProbe',
    'candidateHeadroom',
  ])
    assert.throws(() => nativeRelayImageTag({ ...owned, [key]: false }));
  for (const value of [null, 0, 1, 'true', 'false'])
    assert.throws(() => nativeRelayImageTag({ ...owned, ownedReceiverProbe: value }));
  assert.throws(() => nativeRelayImageTag({ ...owned, repeatedReceiverProbe: true }));
});
