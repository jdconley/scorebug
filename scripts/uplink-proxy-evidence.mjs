import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';

/** Join shutdown once and preserve both its evidence and any export failure. */
export function createUplinkEvidenceStopper({
  uplink,
  artifact,
  capacityEvidencePolicy = 'congestion-v1',
}) {
  assert(
    ['congestion-v1', 'rate-ledger-v1', 'token-budget-v1'].includes(capacityEvidencePolicy),
    'Unsupported capacity evidence policy',
  );
  let stopped;
  return function stop() {
    stopped ??= (async () => {
      const errors = [];
      try {
        await uplink.close();
      } catch (error) {
        errors.push(error);
      }
      try {
        await writeFile(
          join(artifact, 'uplink-proxy.json'),
          JSON.stringify(uplink.snapshot(), null, 2),
          { flag: 'wx' },
        );
      } catch (error) {
        errors.push(error);
      }
      if (capacityEvidencePolicy !== 'congestion-v1') {
        try {
          const evidence = JSON.stringify(uplink.rateLedgerSnapshot());
          assert(Buffer.byteLength(evidence) <= 32 * 1024 * 1024, 'Rate ledger exceeds 32 MiB');
          await writeFile(join(artifact, 'uplink-rate-ledger.json'), evidence, { flag: 'wx' });
        } catch (error) {
          errors.push(error);
        }
      }
      if (errors.length)
        throw new AggregateError(errors, 'Uplink shutdown or evidence export failed');
    })();
    return stopped;
  };
}
