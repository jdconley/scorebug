import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';

/** Caller has joined the collector. These are its already scoped/redacted maps,
 * never raw HTTP responses, private relay inventories or credential stores. */
export async function saveNativeStatusEvidence(
  {
    artifact,
    decodedWindowLimit,
    requirePublication,
    requireReceiverProbe = false,
    receiverProbes,
    collectorError,
    publications,
    workerPublications,
    workerProcessing,
    decodedWindows,
  },
  write = writeFile,
) {
  assert.ok([64, 128].includes(decodedWindowLimit));
  assert.equal(typeof requirePublication, 'boolean');
  assert.equal(typeof requireReceiverProbe, 'boolean');
  assert.ok(!requireReceiverProbe || requirePublication);
  const histories = [
    ['publishing-attempt-status.json', publications, 16],
    ...(requireReceiverProbe ? [['receiver-probe-status.json', receiverProbes, 2048]] : []),
    ...(requirePublication ? [['worker-publication-status.json', workerPublications, 16]] : []),
    ['worker-processing-status.json', workerProcessing, decodedWindowLimit],
    ['decoded-video-status.json', decodedWindows, decodedWindowLimit],
  ];
  const errors = collectorError === undefined ? [] : [collectorError];
  for (const [name, history, limit] of histories) {
    try {
      assert.ok(history instanceof Map && history.size <= limit, 'Status evidence count bound');
      const json = JSON.stringify([...history.values()], null, 2);
      assert.ok(Buffer.byteLength(json) <= 4 * 1024 * 1024, 'Status evidence byte bound');
      await write(join(artifact, name), json);
    } catch (error) {
      errors.push(error);
    }
  }
  try {
    await write(
      join(artifact, 'status-collector.json'),
      JSON.stringify({ stopped: true, failed: collectorError !== undefined }, null, 2),
    );
  } catch (error) {
    errors.push(error);
  }
  if (errors.length)
    throw new AggregateError(errors, 'Collecting or saving native status evidence failed');
}
