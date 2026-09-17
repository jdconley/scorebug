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
