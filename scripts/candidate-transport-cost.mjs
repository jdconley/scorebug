const MAX_INT64 = 9223372036854775807n;
const VIDEO_LIMIT = 2 * 1024 * 1024;

function requireValue(condition, reason) {
  if (!condition) throw new Error(`Candidate transport: ${reason}`);
}
function integer(value, minimum, maximum, label) {
  requireValue(Number.isSafeInteger(value) && value >= minimum && value <= maximum, label);
  return value;
}
function time(value) {
  requireValue(
    value && typeof value.value === 'string' && /^(0|[1-9][0-9]{0,18})$/.test(value.value),
    'invalid time value',
  );
  const numerator = BigInt(value.value);
  requireValue(
    numerator <= MAX_INT64 && value.epoch === '0' && [1, 3].includes(value.flags),
    'invalid time metadata',
  );
  return { n: numerator, d: BigInt(integer(value.timescale, 1, 2147483647, 'invalid timescale')) };
}
const compare = (a, b) => a.n * b.d - b.n * a.d;
const minimum = (a, b) => (!a || compare(b, a) < 0n ? b : a);
const maximum = (a, b) => (!a || compare(b, a) > 0n ? b : a);
const within = (low, high, n, d = 1n) =>
  (high.n * low.d - low.n * high.d) * d <= n * high.d * low.d;

/** Replay the bounded H.264/AAC publishing mux from ordered scalar receipts.
 * This checks application payload cost, not media decoding or network capacity.
 * Keep this independent of native totals; rational clocks avoid rounding large PTS.
 */
export function replayCandidateTransportCost(inputs) {
  requireValue(Array.isArray(inputs) && inputs.length > 1 && inputs.length <= 633, 'input count');
  const result = {
    transportBytes: 0,
    transportMessageCount: 0,
    videoInputBytes: 0,
    audioInputBytes: 0,
    videoInputCount: 0,
    audioInputCount: 0,
    programWrites: 0,
    pcrCount: 0,
    writes: [],
  };
  let firstPTS, lastPTS, previousVideo, previousAudio, parameterBytes;
  let startupLow,
    startupHigh,
    pendingBytes = 0,
    origin,
    lastPCR = 0n,
    rotated = 0n;
  const pending = [];
  const write = (media, inputIndex, byteCount) => {
    requireValue(byteCount <= VIDEO_LIMIT + 65536, 'output byte limit');
    const messageCount = Math.ceil(byteCount / 1316);
    result.writes.push({ media, inputIndex, byteCount, messageCount });
    result.transportBytes += byteCount;
    result.transportMessageCount += messageCount;
  };
  const program = (inputIndex) => {
    result.programWrites++;
    write('program', inputIndex, 376);
  };
  const clock = (source) => {
    const delta = source.n * origin.d - origin.n * source.d;
    requireValue(delta >= 0n, 'timestamp before origin');
    const ticks = (delta * 90000n) / (source.d * origin.d);
    requireValue(ticks + 9000n <= MAX_INT64, 'transport timestamp overflow');
    return ticks;
  };
  const emit = (packet) => {
    clock(packet.pts);
    const ticks = clock(packet.dts ?? packet.pts);
    const pcr = packet.media === 'video' && ticks >= lastPCR && ticks - lastPCR >= 1800n;
    if (pcr) {
      result.pcrCount++;
      lastPCR = ticks;
    }
    if (ticks >= rotated && ticks - rotated > 180000n) {
      program(packet.index);
      rotated = ticks;
    }
    const packets = 1 + Math.ceil(Math.max(0, packet.pesBytes - (pcr ? 176 : 183)) / 184);
    write(packet.media, packet.index, packets * 188);
  };
  for (const [index, input] of inputs.entries()) {
    requireValue(
      input && ['video', 'audio'].includes(input.media) && typeof input.isSync === 'boolean',
      'invalid media',
    );
    const isVideo = input.media === 'video';
    const bytes = integer(
      input.byteCount,
      isVideo ? 5 : 1,
      isVideo ? VIDEO_LIMIT : 8184,
      'input bytes',
    );
    integer(input.parameterSetBytes, 0, 65600, 'parameter bytes');
    const pts = time(input.sourcePTS);
    const dts = input.decodePTS === null ? null : time(input.decodePTS);
    const previous = isVideo ? previousVideo : previousAudio;
    requireValue(!previous || compare(pts, previous) > 0n, 'non-increasing track PTS');
    firstPTS = minimum(firstPTS, pts);
    lastPTS = maximum(lastPTS, pts);
    requireValue(within(firstPTS, lastPTS, 17n, 4n), 'source span');
    if (isVideo) {
      requireValue(++result.videoInputCount <= 121, 'video count');
      if (parameterBytes === undefined) {
        requireValue(input.isSync && input.parameterSetBytes >= 10, 'initial keyframe parameters');
        parameterBytes = input.parameterSetBytes;
      }
      requireValue(
        input.parameterSetBytes === (input.isSync ? parameterBytes : 0),
        'changed video format',
      );
      requireValue(bytes + parameterBytes + 6 <= VIDEO_LIMIT, 'video payload limit');
      previousVideo = pts;
      result.videoInputBytes += bytes;
    } else {
      requireValue(++result.audioInputCount <= 512, 'audio count');
      requireValue(input.isSync && input.parameterSetBytes === 0 && dts === null, 'audio metadata');
      previousAudio = pts;
      result.audioInputBytes += bytes;
    }
    requireValue(
      result.videoInputBytes + result.audioInputBytes <= 32 * 1024 * 1024,
      'cumulative input bytes',
    );
    const pesBytes = bytes + (isVideo ? 6 + input.parameterSetBytes : 7) + (dts ? 19 : 14);
    const packet = { index, media: input.media, pts, dts, pesBytes };
    if (origin) {
      emit(packet);
      continue;
    }
    startupLow = minimum(startupLow, minimum(pts, dts ?? pts));
    startupHigh = maximum(startupHigh, maximum(pts, dts ?? pts));
    requireValue(within(startupLow, startupHigh, 2n), 'startup source span');
    // TSWriter first budgets the full format before constructing PES, even
    // though non-keyframes omit those parameter sets from their actual output.
    const preflightBytes = bytes + (isVideo ? parameterBytes + 6 : 0);
    requireValue(pendingBytes + preflightBytes <= 8 * 1024 * 1024, 'startup payload preflight');
    requireValue(
      pending.length < 256 && pesBytes <= VIDEO_LIMIT && pendingBytes + pesBytes <= 8 * 1024 * 1024,
      'startup retention',
    );
    pending.push(packet);
    pendingBytes += pesBytes;
    if (previousAudio && previousVideo) {
      origin = startupLow;
      program(null);
      for (const retained of pending) emit(retained);
      pending.length = 0;
    }
  }
  requireValue(origin && pending.length === 0, 'incomplete tracks');
  return result;
}
