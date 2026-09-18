export const repeatedProbeScope = {
  recordingID: 'r',
  matchID: 'm',
  broadcastGeneration: 1,
  publishingAttemptID: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  appliedProfileRevision: '0',
};
const id = (n) => `bbbbbbbb-bbbb-4bbb-8bbb-${String(n).padStart(12, '0')}`;
const rates = [500_000, 2_000_000, 12_000_000];
export function repeatedNativeProbeEvidence(ending = 'observed') {
  return {
    formatVersion: 3,
    isClosed: true,
    invalid: false,
    mode: 'repeated',
    result: 'completed',
    scope: { ...repeatedProbeScope },
    publishingGeneration: '7',
    campaigns: [1, 2].map((ordinal) => {
      const origin = ordinal * 30;
      const events = [];
      for (let stage = 1; stage <= 3; stage++) {
        const startedAt = origin + (stage - 1) * 0.25;
        const first = {
          id: id(ordinal * 10 + stage),
          publishingGeneration: '7',
          campaign: String(ordinal),
          stage,
          bitRate: rates[stage - 1],
          startedAt,
          campaignStartedAt: origin,
          leaseDeadline: startedAt + 0.3,
          acceptedPayloadBytes: '0',
          totalAcceptedPayloadBytes: String((stage - 1) * 2632),
          lastAcceptedAt: null,
          reason: null,
        };
        events.push({
          phase: stage === 1 ? 'began' : 'replaced',
          observedAt: startedAt + 0.001,
          sample: first,
        });
        for (let n = 1; n <= 2; n++)
          events.push({
            phase: 'renewed',
            observedAt: startedAt + n * 0.09 + 0.001,
            sample: {
              ...first,
              leaseDeadline: startedAt + n * 0.09 + 0.3,
              acceptedPayloadBytes: String(n * 1316),
              totalAcceptedPayloadBytes: String(((stage - 1) * 2 + n) * 1316),
              lastAcceptedAt: startedAt + n * 0.09 - 0.01,
            },
          });
        if (stage < 3 || ending === 'retired')
          events.push({
            phase: 'retired',
            observedAt: startedAt + 0.21,
            retirementRequestedAt: startedAt + 0.2,
            sample: { ...events.at(-1).sample, reason: 'cancelled' },
          });
        else {
          if (ending === 'renewed') events.at(-1).sample.reason = 'cancelled';
          else
            events.push({
              phase: 'observed',
              observedAt: startedAt + 0.21,
              sample: { ...events.at(-1).sample, reason: 'cancelled' },
            });
          events.push({
            phase: 'final',
            observedAt: startedAt + 0.22,
            sample: { ...events.at(-1).sample },
          });
        }
      }
      return {
        campaign: String(ordinal),
        status: ending === 'retired' ? 'completed' : 'withdrawn',
        isJoined: true,
        context: {
          appliedRevision: String((ordinal - 1) * 2),
          publishingGeneration: '7',
          targetProfile: '360p30',
          targetBitRate: 600000,
          baselineProfile: '240p30',
          baselineBitRate: 350000,
          encoderSessionID: id(100 + ordinal),
          configurationID: id(200 + ordinal),
          acknowledgedAt: origin - 20,
          healthySince: origin - 15,
          healthyThrough: origin - 0.1,
          healthSequence: String(ordinal * 100),
        },
        events,
      };
    }),
  };
}
