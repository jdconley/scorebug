import assert from 'node:assert/strict';
/** Keep staged qualification isolated from previously qualified relay images. */
export function nativeRelayImageTag({
  requirePublication = false,
  requireReceiverProbe = false,
  stagedReceiverProbe = false,
  candidateHeadroom = false,
}) {
  for (const flag of [
    requirePublication,
    requireReceiverProbe,
    stagedReceiverProbe,
    candidateHeadroom,
  ])
    assert.equal(typeof flag, 'boolean');
  assert.ok(!requireReceiverProbe || requirePublication);
  assert.ok(!stagedReceiverProbe || (requireReceiverProbe && requirePublication));
  assert.ok(!candidateHeadroom || stagedReceiverProbe);
  if (candidateHeadroom) return 'scorebug/ingest:staged-probe-hd-v2';
  if (stagedReceiverProbe) return 'scorebug/ingest:staged-probe-v2';
  if (requireReceiverProbe) return 'scorebug/ingest:receiver-probe-v1';
  return requirePublication ? 'scorebug/ingest:recovery-v1' : 'bluenviron/mediamtx:1.21.0';
}
