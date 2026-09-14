import assert from 'node:assert/strict';

const WINDOW_SECONDS = 5;
const MAX_WINDOWS = 128;
function integer(value, label, minimum = 0) {
  if (typeof value === 'string') {
    assert.match(value, /^(0|-?[1-9]\d*)$/, `Invalid ${label}`);
    value = Number(value);
  }
  assert.ok(Number.isSafeInteger(value) && value >= minimum, `Invalid ${label}`);
  return value;
}
function addBytes(current, added) {
  const total = current + added;
  assert.ok(
    Number.isSafeInteger(total) && total <= Math.floor(Number.MAX_SAFE_INTEGER / 8),
    'Overflowing video payload bytes',
  );
  return total;
}
function floorDivide(value, divisor) {
  const quotient = value / divisor;
  return value < 0n && value % divisor !== 0n ? quotient - 1n : quotient;
}
function windowTime(index) {
  const seconds = Number(index * BigInt(WINDOW_SECONDS));
  assert.ok(Number.isSafeInteger(seconds), 'Unsupported media window timestamp range');
  return seconds;
}

/**
 * Video payload demand on the encoded media timeline, not transport throughput.
 * Whole packet bytes belong to the interval containing their PTS. Only complete
 * five-second intervals are reported; gaps remain visible as low/zero windows.
 */
export function measureVideoPayloadRate({ streams, packets }) {
  assert.ok(Array.isArray(streams) && Array.isArray(packets), 'Invalid packet probe');
  const indexes = new Set();
  for (const stream of streams) {
    const index = integer(stream?.index, 'stream index');
    assert.ok(!indexes.has(index), 'Duplicate stream index');
    assert.ok(
      typeof stream.codec_type === 'string' && stream.codec_type.length > 0,
      'Invalid stream type',
    );
    indexes.add(index);
  }
  const videos = streams.filter((stream) => stream.codec_type === 'video');
  assert.equal(videos.length, 1, 'Exactly one video stream is required');
  const video = videos[0];
  assert.ok(typeof video.time_base === 'string', 'Invalid video timebase');
  const match = /^([1-9]\d*)\/([1-9]\d*)$/.exec(video.time_base);
  assert.ok(match, 'Invalid video timebase');
  const numerator = BigInt(integer(match[1], 'timebase numerator', 1));
  const denominator = BigInt(integer(match[2], 'timebase denominator', 1));
  const interval = BigInt(WINDOW_SECONDS) * denominator;
  const videoIndex = integer(video.index, 'video stream index');
  const selected = [];
  let previousPTS;
  let totalBytes = 0;
  for (const packet of packets) {
    const index = integer(packet?.stream_index, 'packet stream index');
    assert.ok(indexes.has(index), 'Unknown packet stream');
    if (index !== videoIndex) continue;
    const pts = integer(packet.pts, 'video packet PTS', -Number.MAX_SAFE_INTEGER);
    const duration = integer(packet.duration, 'video packet duration', 1);
    const size = integer(packet.size, 'video packet size', 1);
    assert.ok(previousPTS === undefined || pts > previousPTS, 'Duplicate or regressed video PTS');
    assert.ok(Number.isSafeInteger(pts + duration), 'Overflowing video packet end');
    previousPTS = pts;
    totalBytes = addBytes(totalBytes, size);
    selected.push({ pts, duration, size, time: BigInt(pts) * numerator });
  }
  assert.ok(selected.length > 0, 'No video packets');
  const first = selected[0],
    last = selected.at(-1);
  const startTime = first.time;
  const endTime = BigInt(last.pts + last.duration) * numerator;
  const startIndex = -floorDivide(-startTime, interval);
  const endIndex = floorDivide(endTime, interval);
  const count = endIndex - startIndex;
  assert.ok(count > 0n && count <= BigInt(MAX_WINDOWS), 'Requires 1..128 complete media windows');
  const windows = Array.from({ length: Number(count) }, (_, i) => ({
    startTimeSeconds: windowTime(startIndex + BigInt(i)),
    endTimeSeconds: windowTime(startIndex + BigInt(i + 1)),
    packetCount: 0,
    payloadBytes: 0,
    megabitsPerSecond: 0,
  }));
  const leadingExcluded = { packetCount: 0, payloadBytes: 0 };
  const trailingExcluded = { packetCount: 0, payloadBytes: 0 };
  for (const packet of selected) {
    const index = floorDivide(packet.time, interval);
    const destination =
      index < startIndex
        ? leadingExcluded
        : index >= endIndex
          ? trailingExcluded
          : windows[Number(index - startIndex)];
    destination.packetCount++;
    destination.payloadBytes = addBytes(destination.payloadBytes, packet.size);
  }
  let packetCount = 0,
    payloadBytes = 0;
  for (const window of windows) {
    window.megabitsPerSecond = (window.payloadBytes * 8) / (WINDOW_SECONDS * 1e6);
    packetCount += window.packetCount;
    payloadBytes = addBytes(payloadBytes, window.payloadBytes);
  }
  const durationSeconds = windows.length * WINDOW_SECONDS;
  return {
    formatVersion: 1,
    videoStreamIndex: videoIndex,
    timeBase: video.time_base,
    attribution: 'whole packet payload assigned by PTS',
    windowSeconds: WINDOW_SECONDS,
    coverage: {
      firstPTS: first.pts,
      lastPTS: last.pts,
      lastDuration: last.duration,
      startTimeSeconds: Number(startTime) / Number(denominator),
      endTimeSeconds: Number(endTime) / Number(denominator),
      packetCount: selected.length,
      payloadBytes: totalBytes,
    },
    leadingExcluded,
    trailingExcluded,
    windows,
    measured: {
      durationSeconds,
      packetCount,
      payloadBytes,
      meanMbps: (payloadBytes * 8) / (durationSeconds * 1e6),
      minMbps: Math.min(...windows.map((window) => window.megabitsPerSecond)),
      maxMbps: Math.max(...windows.map((window) => window.megabitsPerSecond)),
    },
  };
}
