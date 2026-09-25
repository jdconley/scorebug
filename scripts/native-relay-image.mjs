import assert from 'node:assert/strict';
/** Keep each probe route isolated from previously qualified relay images. */
export function nativeRelayImageTag({
  requirePublication = false,
  requireReceiverProbe = false,
  stagedReceiverProbe = false,
  candidateHeadroom = false,
  repeatedReceiverProbe = false,
  ownedReceiverProbe = false,
}) {
  for (const flag of [
    requirePublication,
    requireReceiverProbe,
    stagedReceiverProbe,
    candidateHeadroom,
    repeatedReceiverProbe,
    ownedReceiverProbe,
  ])
    assert.equal(typeof flag, 'boolean');
  assert.ok(!requireReceiverProbe || requirePublication);
  assert.ok(!stagedReceiverProbe || (requireReceiverProbe && requirePublication));
  assert.ok(!candidateHeadroom || stagedReceiverProbe);
  assert.ok(!repeatedReceiverProbe || candidateHeadroom);
  assert.ok(!ownedReceiverProbe || (candidateHeadroom && !repeatedReceiverProbe));
  if (repeatedReceiverProbe || ownedReceiverProbe) return 'scorebug/ingest:campaign-probe-v3';
  if (candidateHeadroom) return 'scorebug/ingest:staged-probe-hd-v2';
  if (stagedReceiverProbe) return 'scorebug/ingest:staged-probe-v2';
  if (requireReceiverProbe) return 'scorebug/ingest:receiver-probe-v1';
  return requirePublication ? 'scorebug/ingest:recovery-v1' : 'bluenviron/mediamtx:1.21.0';
}
