// Synthetic raw preflight metadata for unit tests on existing scalar chronologies.
// This mutates only caller-owned test data; it never qualifies a recorded run.
export function addSyntheticRecoveryProbeEvidence(value) {
  if (!value || typeof value !== 'object') return;
  if (Object.hasOwn(value, 'acceptedPayloadBytes') && Object.hasOwn(value, 'startedAt')) {
    value.policy = 'recovery-budget-v1';
    const at = value.lastAcceptedAt ?? value.startedAt;
    value.recoveryObservation = {
      checkedAt: at,
      sampledAt: at,
      elapsedMilliseconds: String(Math.round(at * 1000)),
      sentBytes: String(10000000n + BigInt(value.acceptedPayloadBytes)),
      retransmittedBytes: String(BigInt(value.acceptedPayloadBytes) / 1000n),
      droppedPackets: 0,
      rttMilliseconds: 65,
      senderBufferMilliseconds: 67,
      senderDeliveryDelayMilliseconds: 400,
    };
  }
  if (value.convention === 'measured-candidate-ipv4-v1') {
    value.formatVersion = 2;
    value.convention = 'measured-candidate-ipv4-recovery-v1';
  }
  for (const child of Object.values(value)) addSyntheticRecoveryProbeEvidence(child);
}
