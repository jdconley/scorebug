import { probeBackend } from './backend-capabilities.js';
import { loadConfig, videoProfiles } from './config.js';
import { createLogger } from './logger.js';
import { startPipeline } from './pipeline.js';
import { allocatePipelineOutputs } from './output-recording.js';
import { scoreFilePath } from './score-file.js';
import { WorkerClient } from './worker-client.js';
import { WorkerSupervisor } from './supervisor.js';
import { WorkerReporter } from './worker-reporter.js';
import { createWorkerStateLogger } from './worker-state-log.js';
import { createWorkerTerminalDiagnostics, flushWorkerDiagnostics } from './worker-terminal.js';
import { probeEncoderStatistics } from './encoder-statistics-capability.js';

const config = loadConfig();
const log = createLogger(config.LOG_LEVEL);
const terminalDiagnostics = createWorkerTerminalDiagnostics(
  log,
  process.env.SCOREBUG_TEST_WORKER_TERMINAL,
  process.env.SCOREBUG_TEST_WORKER_PACKET_TIMING,
  process.env.SCOREBUG_TEST_WORKER_DECODED_GEOMETRY,
);
const scoreFile = scoreFilePath(config.SCORE_DIR);
const client = new WorkerClient(config.CONTROL_PLANE_URL, config.HOME_TOKEN, config.WORKER_ID);
let reporter: WorkerReporter;
let encoderTiming = false;
const startupAbort = new AbortController();
let startupProbe: Promise<unknown>;
const supervisor = new WorkerSupervisor({
  load: () => client.load(),
  scoreFile,
  outputId: config.OUTPUT_ID,
  onState: createWorkerStateLogger(log),
  start: (input, onProgress, metadata) => {
    const diagnostics = terminalDiagnostics.scope(input, metadata);
    return startPipeline(
      {
        gameId: input.gameId,
        pullUrl: input.readUrl,
        ...allocatePipelineOutputs(config),
        scoreFile,
        nvenc: false,
        encoder: config.ENCODER,
        decoderThreading: config.DECODER_THREADING,
        profile: videoProfiles[config.VIDEO_PROFILE],
        ffmpegPath: config.FFMPEG_PATH,
      },
      diagnostics.log,
      {
        onProgress,
        stopTimeoutMs: 1000,
        encoderTiming,
        deliveryTimeline: true,
        packetTiming: terminalDiagnostics.packetTimingEnabled,
        decodedGeometry: terminalDiagnostics.decodedGeometryEnabled,
        ...(diagnostics.onTerminal && { onTerminal: diagnostics.onTerminal }),
      },
    );
  },
});
let stopping = false;
let timer: ReturnType<typeof setTimeout> | undefined;
let reportTimer: ReturnType<typeof setTimeout> | undefined;
let reportingFailed = false;
const report = async () => {
  let sampledObservation = false;
  try {
    await reporter.report(() => {
      const observation = supervisor.observation();
      sampledObservation = observation !== null;
      return observation;
    });
    if (sampledObservation) {
      if (reportingFailed) log.info('worker_reporting_recovered');
      reportingFailed = false;
    }
  } catch {
    if (!reportingFailed) log.warn('worker_reporting_unavailable');
    reportingFailed = true;
  }
  if (!stopping) reportTimer = setTimeout(() => void report(), config.WORKER_REPORT_INTERVAL_MS);
};
const poll = async () => {
  try {
    await supervisor.tick();
  } catch {
    log.error('worker_tick_failed');
  }
  if (!stopping) timer = setTimeout(() => void poll(), 500);
};
const shutdown = async () => {
  if (stopping) return;
  stopping = true;
  clearTimeout(timer);
  clearTimeout(reportTimer);
  startupAbort.abort();
  await Promise.all([supervisor.close(), startupProbe]);
  if (terminalDiagnostics.enabled) await flushWorkerDiagnostics(process.stdout);
  process.exit(0);
};
process.on('SIGINT', () => void shutdown());
process.on('SIGTERM', () => void shutdown());
log.info('worker_started', {
  workerId: config.WORKER_ID,
  outputId: config.OUTPUT_ID,
  outputMode: config.OUTPUT_MODE,
  encoder: config.ENCODER,
  decoderThreading: config.DECODER_THREADING,
  profile: config.VIDEO_PROFILE,
});
if (config.WORKER_PROCESSING === 'off') log.info('worker_processing_disabled');
startupProbe = Promise.all([
  probeBackend(config, { signal: startupAbort.signal }),
  config.WORKER_PROCESSING === 'off'
    ? Promise.resolve(undefined)
    : probeEncoderStatistics(config.FFMPEG_PATH, { signal: startupAbort.signal }),
]).then(([backend, statistics]) => {
  if (stopping) return;
  reporter = new WorkerReporter(
    config.CONTROL_PLANE_URL,
    config.HOME_TOKEN,
    config.WORKER_ID,
    undefined,
    undefined,
    backend,
  );
  log.info('worker_backend_capabilities', backend);
  if (statistics) encoderTiming = statistics.available;
  log.info('worker_processing_capability', statistics ?? { available: false, reason: 'disabled' });
  void poll();
  void report();
});
