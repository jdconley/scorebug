import { ordinary720Fixture, ordinary720GeometryFixture } from './ordinary720-evidence.mjs';

function physicalStartup(input) {
  const { native, audit } = input;
  native.formatVersion = 3;
  native.contract = 'physical-recovery720-v1';
  native.captureSource = 'physical-camera';
  native.localPublishingObservedUptimeSeconds = 1002;
  native.workerOutputObservedUptimeSeconds = 1012;
  for (const sample of native.samples) {
    const d = sample.diagnostic;
    d.policyAppliedRevision = String(Number(d.policyAppliedRevision) - 1);
    if (d.appliedTransition) {
      const receipt = JSON.parse(d.appliedTransition);
      receipt.revision = String(Number(receipt.revision) - 1);
      receipt.fromRevision = String(Number(receipt.fromRevision) - 1);
      d.appliedTransition = JSON.stringify(receipt);
    }
  }
  const minimum = native.samples[0];
  minimum.phase = 'initial-source-ready';
  minimum.readStartedUptimeSeconds = 1025;
  minimum.readEndedUptimeSeconds = 1025.1;
  Object.assign(minimum.diagnostic, {
    sessionObservedAtUptimeSeconds: '1024.85',
    observedAtUptimeSeconds: '1024.9',
    policyAcceptedSourceWindowEnd: '1024.8',
    policyDecodedPreviousPTS: '1800000',
    policyDecodedFirstPTS: '1803000',
    policyDecodedLastPTS: '2250000',
  });
  const encoder = structuredClone(minimum);
  encoder.phase = 'initial-encoder-ack';
  encoder.readStartedUptimeSeconds = 1006;
  encoder.readEndedUptimeSeconds = 1006.1;
  encoder.diagnostic.sessionObservedAtUptimeSeconds = '1005.85';
  encoder.diagnostic.observedAtUptimeSeconds = '1005.9';
  for (const key of Object.keys(encoder.diagnostic))
    if (/^policy(Owner|Source|AcceptedSource|Decoded|Pipeline)/.test(key))
      delete encoder.diagnostic[key];
  native.samples.unshift(encoder);
  for (const milestone of native.milestones) {
    milestone.sampleIndex++;
    if (milestone.phase === 'initial-minimum') {
      milestone.phase = 'initial-source-ready';
      milestone.uptimeSeconds = 1025.1;
    }
  }
  native.milestones.unshift(
    { phase: 'local-publishing-observed', uptimeSeconds: 1002 },
    { phase: 'initial-encoder-ack', sampleIndex: 0, uptimeSeconds: 1006.1 },
    { phase: 'worker-output-observed', uptimeSeconds: 1012 },
  );
  Object.assign(native.gates[0], {
    phase: 'initial-source-ready',
    startedUptimeSeconds: 1012,
    limitSeconds: 30,
  });
  native.gates[1].startedUptimeSeconds = 1025.1;
  native.gates.unshift({
    phase: 'initial-encoder-ack',
    startedUptimeSeconds: 1002,
    limitSeconds: 10,
  });
  audit.records[0].diagnostic = structuredClone(native.samples[5].diagnostic);
  audit.records[1].diagnostic = structuredClone(native.samples[6].diagnostic);
  return input;
}
export function physical720Fixture() {
  return physicalStartup(ordinary720Fixture());
}
export function physical720GeometryFixture() {
  return physicalStartup(ordinary720GeometryFixture());
}
