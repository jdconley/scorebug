import assert from 'node:assert/strict';
import { qualifyRepeatedNativeCandidateMeasurements } from '../../repeated-native-candidate-measurement.mjs';

/** Add the adapter's captured witness fields to a synthetic receiver fixture.
 * The verifier must replay this fixed selection, never choose a better pair.
 */
export function withRepeatedAdmissionWitnesses(input) {
  const f = structuredClone(input);
  const measured = qualifyRepeatedNativeCandidateMeasurements(f.candidateProof, {
    ...f,
    nativeProbe: f.probe,
  });
  const rows = f.intervals.intervals;
  const decisions = f.quality.events.filter((e) => e.kind === 'candidate');
  for (const [index, decision] of decisions.entries()) {
    const cost = measured.campaigns[index],
      p = f.candidateProof.campaigns[index].measurement;
    const m = p.measurement,
      now = decision.candidate.evaluatedAt;
    const selected = rows
      .map((r, rowIndex) => ({ r, rowIndex }))
      .filter(
        ({ r }) =>
          r.nativeProbeCampaign === cost.campaign &&
          r.nativeProbeStage === 3 &&
          r.evaluatedAt <= now,
      )
      .slice(-2);
    assert.equal(selected.length, 2);
    const intervals = selected.map(({ r, rowIndex }) => {
      const receivedAt = r.requestStartedAt + r.requestDurationMs / 1000;
      const receiverAt = Number(r.end.observedAtNanoseconds) / 1e9;
      const offset = [
        Math.max(
          ...rows
            .slice(0, rowIndex + 1)
            .map(
              (prior) =>
                prior.requestStartedAt -
                prior.serverAgeUpperBoundMs / 1000 -
                Number(prior.end.observedAtNanoseconds) / 1e9,
            ),
        ),
        Math.min(
          receivedAt - receiverAt,
          ...rows
            .slice(0, rowIndex + 1)
            .map(
              (prior) => prior.responseReceivedAt - Number(prior.end.observedAtNanoseconds) / 1e9,
            ),
        ),
      ];
      assert.ok(offset[0] <= offset[1]);
      const age = r.serverAgeUpperBoundMs / 1000 + now - r.requestStartedAt;
      const deliveryAge =
        Number(BigInt(r.end.observedAtNanoseconds) - BigInt(r.end.lastDeliveredAtNanoseconds)) /
        1e9;
      const project = (snapshot) =>
        offset.map((n) => n + Number(snapshot.observedAtNanoseconds) / 1e9);
      return {
        start: structuredClone(r.start),
        end: {
          expected: {
            gameId: f.scope.matchID,
            generation: f.scope.broadcastGeneration,
            workerId: r.workerId,
            publishingAttemptId: f.scope.publishingAttemptID.toLowerCase(),
            publishingGeneration: f.probe.publishingGeneration,
            probeId: r.nativeProbeId.toLowerCase(),
            stage: 3,
            campaign: cost.campaign,
            bitRate: 12000000,
          },
          snapshot: structuredClone(r.end),
          publication: structuredClone(r.publication),
          workerEpoch: r.workerEpoch,
          workerAttempt: r.workerAttempt,
          serverAgeUpperBoundMs: r.serverAgeUpperBoundMs,
          requestStartedAtUptimeBounds: [r.requestStartedAt, r.requestStartedAt],
          receivedAtUptimeBounds: [receivedAt, receivedAt],
          requestDurationSeconds: r.requestDurationMs / 1000,
          snapshotAgeUpperBoundSeconds: age,
          lastDeliveryAgeUpperBoundSeconds: age + deliveryAge,
        },
        durationNanoseconds: r.durationNanoseconds,
        deliveredMessages: r.deliveredMessages,
        deliveredPayloadBytesLowerBound: r.deliveredPayloadBytesLowerBound,
        payloadBitsPerSecondLowerBound: r.payloadBitsPerSecondLowerBound,
        receiverClockOffsetUptimeBounds: offset,
        startUptimeBounds: project(r.start),
        endUptimeBounds: project(r.end),
      };
    });
    const newest = intervals[1];
    const witness = {
      formatVersion: 1,
      convention: 'measured-candidate-ipv4-v1',
      measurement: {
        id: m.id,
        scope: m.scope,
        profile: m.profile,
        publishingGeneration: m.transport.publishingGeneration,
        startedAt: m.startedAt,
        endedAt: m.endedAt,
        firstInputAt: m.encoding.frames[0].admittedAt,
        lastInputAt: m.encoding.frames.at(-1).admittedAt,
        sourceDuration: cost.sourceDuration,
        submissionDuration: cost.submissionDuration,
        transportBytes: cost.transport.transportBytes,
        transportMessageCount: cost.transport.transportMessageCount,
      },
      applied: structuredClone(decision.candidateAdmission.applied),
      binding: structuredClone(decision.candidateAdmission.binding),
      probe: structuredClone(decision.candidateAdmission.probe),
      boundAt: p.probeBinding.boundAt,
      completedAt: p.probeBinding.completedAt,
      clock: {
        before: now,
        after: now,
        receiverClockOffsetUptimeBounds: newest.receiverClockOffsetUptimeBounds,
      },
      intervals,
      evaluatedAt: now,
    };
    witness.validUntil = Math.min(
      m.endedAt + 2,
      witness.probe.leaseDeadline,
      now + 1.5 - newest.end.snapshotAgeUpperBoundSeconds,
      now + 1.5 - newest.end.lastDeliveryAgeUpperBoundSeconds,
    );
    witness.candidateTransportBitsPerSecond =
      ((cost.transport.transportBytes + 44 * cost.transport.transportMessageCount) * 8) /
      Math.min(cost.sourceDuration, cost.submissionDuration);
    witness.deliveredPaddingBitsPerSecond = Math.min(
      ...intervals.map((i) => i.payloadBitsPerSecondLowerBound),
    );
    decision.candidateAdmission = witness;
    decision.candidate.validUntil = witness.validUntil;
    decision.candidate.candidateTransportBitsPerSecond = witness.candidateTransportBitsPerSecond;
    decision.candidate.deliveredPaddingBitsPerSecond = witness.deliveredPaddingBitsPerSecond;
  }
  return f;
}
