import assert from 'node:assert/strict';

/** Validate only the bounded diagnostic join. Software and unavailable selection
 * are valid outcomes, never streaming failure or inferred capacity evidence. */
export function diagnoseNativeEncoderSelection(evidence) {
  assert.equal(evidence?.submissionOverflow, false);
  const rows = evidence.submissionCalls;
  assert(
    Array.isArray(rows) && rows.length > 0 && rows.length <= 512,
    'Missing bounded encoder submissions',
  );
  const sessions = new Map();
  for (const row of rows) {
    assert.match(row.encoderSessionID, /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i);
    const id = row.encoderSessionID.toLowerCase(),
      selection = row.selectionQueriedAfterPreparation;
    assert(
      selection && typeof selection === 'object' && !Array.isArray(selection),
      'Missing encoder selection',
    );
    assert.deepEqual(Object.keys(selection).sort(), ['nativeStatus', 'state']);
    if (selection.state === 'readFailed') {
      assert(
        Number.isInteger(selection.nativeStatus) &&
          selection.nativeStatus !== 0 &&
          selection.nativeStatus >= -2147483648 &&
          selection.nativeStatus <= 2147483647,
      );
    } else {
      assert(
        ['hardware', 'software', 'missingValue', 'invalidType', 'notQueriedOnPlatform'].includes(
          selection.state,
        ),
      );
      assert.equal(selection.nativeStatus, null);
    }
    const existing = sessions.get(id);
    if (existing) {
      assert.deepEqual(
        existing.selection,
        selection,
        'Cached selection changed within encoder session',
      );
      existing.submissions++;
    } else sessions.set(id, { encoderSessionID: id, submissions: 1, selection: { ...selection } });
  }
  return {
    diagnosticOnly: true,
    measurement: 'selectionQueriedAfterPreparation',
    submissions: rows.length,
    sessions: [...sessions.values()],
  };
}
