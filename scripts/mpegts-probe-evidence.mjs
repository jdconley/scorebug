import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
const count = (n) => Number.isSafeInteger(n) && n >= 0;
const time = (n) => Number.isFinite(n) && n >= 0;
const near = (a, b) => time(a) && time(b) && Math.abs(a - b) < 0.00001;

function transport(bytes) {
  assert(Buffer.isBuffer(bytes) && bytes.length > 0 && bytes.length <= 32 * 1024 * 1024);
  assert.equal(bytes.length % 188, 0);
  const media = [];
  let nullPackets = 0;
  for (let at = 0; at < bytes.length; at += 188) {
    assert.equal(bytes[at], 0x47);
    assert.equal(bytes[at + 1] & 0x80, 0);
    assert.notEqual(bytes[at + 3] & 0x30, 0);
    const pid = bytes.readUInt16BE(at + 1) & 0x1fff;
    if (pid === 0x1fff) nullPackets++;
    else media.push(bytes.subarray(at, at + 188));
  }
  return { media: Buffer.concat(media), nullPackets };
}
export function qualifyMPEGTSProbe({
  source,
  accepted,
  received,
  senderRows,
  receiverRows,
  scenario,
}) {
  assert(['baseline', 'lease', 'pressure'].includes(scenario));
  const original = transport(source),
    delivered = transport(received);
  assert(accepted.equals(received), 'Accepted/delivered transport differs');
  assert(original.media.equals(delivered.media), 'Original media transport changed');
  for (const rows of [senderRows, receiverRows]) {
    assert(rows.length > 0 && rows.length <= 2500);
    let previous = -1;
    for (const row of rows) {
      assert(time(row.at) && row.at >= previous, 'Native time reversed');
      previous = row.at;
    }
    assert.equal(rows.at(-1).kind, 'finished');
    assert.equal(rows.at(-1).requestedStop, true);
    assert.equal(rows.at(-1).transportBytes, accepted.length);
  }
  const last = senderRows.at(-1);
  assert.equal(last.sourceBytes, source.length);
  assert(
    Number.isSafeInteger(last.probeBytes) &&
      last.probeBytes >= 0 &&
      last.probeBytes <= 16 * 1024 * 1024,
  );
  assert.equal(last.probeBytes % 1316, 0);
  assert.equal(accepted.length, source.length + last.probeBytes);
  assert.equal(delivered.nullPackets - original.nullPackets, last.probeBytes / 188);
  const withdrawals = senderRows.filter((r) => r.kind === 'withdrawn');
  const starts = senderRows.filter((r) => r.kind === 'probe-start');
  let withdrawal = null;
  if (scenario === 'baseline') {
    assert.equal(last.probeBytes, 0);
    assert.equal(withdrawals.length, 0);
    assert.equal(starts.length, 0);
  } else {
    assert(last.probeBytes > 0);
    assert.equal(starts.length, 1);
    assert.equal(withdrawals.length, 1);
    withdrawal = withdrawals[0];
    const start = starts[0];
    assert(count(start.rateBps) && start.rateBps > 0 && start.rateBps <= 2_000_000);
    assert(count(start.retransmittedBytes) && count(start.droppedPackets));
    let deadline = start.deadline;
    assert(near(deadline, start.at + 0.3), 'Invalid initial lease');
    for (const renewal of senderRows.filter((r) => r.kind === 'lease')) {
      assert(renewal.at >= start.at && typeof renewal.renewed === 'boolean');
      if (renewal.renewed) {
        assert(
          renewal.at < deadline && renewal.at < withdrawal.at,
          'Expired/terminal lease revived',
        );
        assert(near(renewal.deadline, renewal.at + 0.3));
        deadline = renewal.deadline;
      } else assert(near(renewal.deadline, deadline));
    }
    assert(
      near(withdrawal.deadline, deadline),
      'Withdrawal deadline differs from applied renewals',
    );
    assert(
      time(withdrawal.lastAcceptedAt) &&
        withdrawal.lastAcceptedAt >= start.at &&
        withdrawal.lastAcceptedAt < deadline &&
        withdrawal.lastAcceptedAt <= withdrawal.at,
    );
    assert.equal(withdrawal.reason, scenario === 'lease' ? 'lease-expired' : 'transport-pressure');
    assert(withdrawal.at > start.at);
    assert(
      time(withdrawal.statisticsAt) &&
        withdrawal.statisticsAt <= withdrawal.at &&
        withdrawal.at - withdrawal.statisticsAt <= 0.1 &&
        withdrawal.statisticsAt >= start.at,
    );
    assert(time(withdrawal.rttMs) && time(withdrawal.bufferMs));
    for (const key of ['retransmittedBytes', 'droppedPackets'])
      assert(count(withdrawal[key]) && withdrawal[key] >= start[key]);
    if (scenario === 'lease') {
      assert(
        withdrawal.at >= deadline && withdrawal.at - deadline < 0.05,
        'Lease withdrawal is early or more than 50 ms late',
      );
    } else {
      assert(withdrawal.at < deadline, 'Pressure withdrawal arrived after lease expiry');
      assert(
        withdrawal.rttMs > 50 ||
          withdrawal.bufferMs > 50 ||
          withdrawal.retransmittedBytes > start.retransmittedBytes ||
          withdrawal.droppedPackets > start.droppedPackets,
        'No measured pressure cause',
      );
    }
    assert(source.length - withdrawal.sourceBytes > 350000, 'No sustained media continuation');
    for (const row of senderRows.filter((r) => r.at >= withdrawal.at && r.probeBytes !== undefined))
      assert.equal(row.probeBytes, withdrawal.probeBytes, 'Padding continued after withdrawal');
  }
  let previous = { sourceBytes: 0, transportBytes: 0, probeBytes: 0 };
  for (const row of senderRows.filter((r) =>
    ['probe-start', 'withdrawn', 'sample', 'finished'].includes(r.kind),
  )) {
    for (const key of ['sourceBytes', 'transportBytes', 'probeBytes']) {
      assert(Number.isSafeInteger(row[key]) && row[key] >= previous[key] && row[key] <= last[key]);
    }
    assert.equal(row.transportBytes, row.sourceBytes + row.probeBytes);
    previous = row;
  }
  return {
    sourceBytes: source.length,
    deliveredBytes: received.length,
    probeBytes: last.probeBytes,
    probePackets: last.probeBytes / 188,
    sourceNullPackets: original.nullPackets,
    receivedNullPackets: delivered.nullPackets,
    withdrawal,
    deliveredSHA256: createHash('sha256').update(received).digest('hex'),
    mediaSHA256: createHash('sha256').update(delivered.media).digest('hex'),
  };
}
