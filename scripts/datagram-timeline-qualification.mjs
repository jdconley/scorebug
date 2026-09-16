import assert from 'node:assert/strict';
const kinds = [
  'received',
  'forwarded',
  'injectedDrop',
  'overflowDrop',
  'oversizeDrop',
  'closeDiscard',
];
const safe = (n) => Number.isSafeInteger(n) && n >= 0;
const time = (n) => Number.isFinite(n) && n >= 0 && n <= 1e12;
/** Verify observation completeness, not successful delivery or native clock correlation. */
export function qualifyDatagramTimeline(queue) {
  const t = queue.timeline;
  assert(
    t && t.windowMilliseconds === 100 && t.capacity === 8192,
    'Missing/unknown queue timeline',
  );
  assert(Array.isArray(t.windows) && t.windows.length <= 8192);
  assert(safe(t.omittedEvents));
  if (t.firstObservedAt === null) {
    assert.equal(t.lastObservedAt, null);
    assert.equal(t.windows.length, 0);
  } else
    assert(
      time(t.firstObservedAt) && time(t.lastObservedAt) && t.lastObservedAt >= t.firstObservedAt,
    );
  const totals = Object.fromEntries(kinds.map((k) => [k, { packets: 0, wireBytes: 0 }]));
  let end = -1;
  let balancePackets = 0,
    balanceBytes = 0;
  for (const w of t.windows) {
    assert(
      safe(w.start) && w.start % 100 === 0 && w.start >= end && w.end === w.start + 100,
      'Invalid timeline window',
    );
    assert(t.firstObservedAt !== null && w.end > t.firstObservedAt && w.start <= t.lastObservedAt);
    end = w.end;
    assert(safe(w.peakQueuePackets) && w.peakQueuePackets <= queue.configuration.maxQueuePackets);
    assert(safe(w.peakQueueBytes) && w.peakQueueBytes <= queue.configuration.maxQueueBytes);
    assert(time(w.maximumForwardResidenceMilliseconds));
    assert(w.maximumForwardResidenceMilliseconds <= t.lastObservedAt - t.firstObservedAt);
    for (const k of kinds)
      for (const unit of ['packets', 'wireBytes']) {
        assert(safe(w[k][unit]));
        totals[k][unit] += w[k][unit];
        assert(safe(totals[k][unit]));
      }
  }
  for (const w of t.windows) {
    const priorPackets = balancePackets,
      priorBytes = balanceBytes;
    for (const k of kinds) {
      assert(w[k].wireBytes >= w[k].packets * 28, 'Impossible packet/byte count');
      assert.equal(w[k].packets === 0, w[k].wireBytes === 0);
      const sign = k === 'received' ? 1 : -1;
      balancePackets += sign * w[k].packets;
      balanceBytes += sign * w[k].wireBytes;
    }
    assert(
      safe(balancePackets) && balancePackets <= queue.configuration.maxQueuePackets,
      'Impossible queue chronology',
    );
    assert(
      safe(balanceBytes) && balanceBytes <= queue.configuration.maxQueueBytes,
      'Impossible queue chronology',
    );
    assert(
      balanceBytes >= balancePackets * 28 &&
        balanceBytes <= balancePackets * (queue.configuration.maxDatagramBytes + 28),
    );
    assert(w.peakQueuePackets >= Math.max(priorPackets, balancePackets));
    assert(w.peakQueueBytes >= Math.max(priorBytes, balanceBytes));
  }
  let omittedEvents = 0;
  for (const k of kinds) {
    for (const unit of ['packets', 'wireBytes']) {
      assert(safe(t.omitted[k][unit]) && safe(queue[k][unit]));
      assert.equal(
        totals[k][unit] + t.omitted[k][unit],
        queue[k][unit],
        'Timeline counter mismatch',
      );
    }
    assert.equal(t.omitted[k].packets === 0, t.omitted[k].wireBytes === 0);
    assert(t.omitted[k].wireBytes >= t.omitted[k].packets * 28);
    omittedEvents += t.omitted[k].packets;
    assert(safe(omittedEvents));
  }
  assert.equal(omittedEvents, t.omittedEvents);
  if (t.omittedEvents) assert.equal(t.windows.length, t.capacity);
  const overflow = t.windows.filter((w) => w.overflowDrop.packets > 0);
  return {
    complete: t.omittedEvents === 0,
    windowCount: t.windows.length,
    omittedEvents: t.omittedEvents,
    firstOverflowAt: overflow[0]?.start ?? null,
    lastOverflowBefore: overflow.at(-1)?.end ?? null,
    peakReceivedWireBytesPerBin: Math.max(0, ...t.windows.map((w) => w.received.wireBytes)),
    maximumForwardResidenceMilliseconds: Math.max(
      0,
      ...t.windows.map((w) => w.maximumForwardResidenceMilliseconds),
    ),
    scope:
      'Queue-clock bins, counters and local send attempts only; no native frame/packet or cross-clock causality.',
  };
}
