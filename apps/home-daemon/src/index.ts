import { loadConfig, videoProfiles } from './config.js';
import { createLogger } from './logger.js';
import { startPipeline } from './pipeline.js';
import { allocatePipelineOutputs } from './output-recording.js';
import { scoreFilePath } from './score-file.js';
import { WorkerClient } from './worker-client.js';
import { WorkerSupervisor } from './supervisor.js';
import { WorkerReporter } from './worker-reporter.js';
import { createWorkerStateLogger } from './worker-state-log.js';

const config = loadConfig();
const log = createLogger(config.LOG_LEVEL);
const scoreFile = scoreFilePath(config.SCORE_DIR);
const client = new WorkerClient(config.CONTROL_PLANE_URL, config.HOME_TOKEN, config.WORKER_ID);
const profile = videoProfiles[config.VIDEO_PROFILE];
const reporter = new WorkerReporter(
  config.CONTROL_PLANE_URL,
  config.HOME_TOKEN,
  config.WORKER_ID,
  undefined,
  undefined,
  profile,
  config.OUTPUT_ID,
);
const supervisor = new WorkerSupervisor({
  load: () => client.load(),
  scoreFile,
  outputId: config.OUTPUT_ID,
  onState: createWorkerStateLogger(log),
  scoreDelayMs: config.SCORE_DELAY_MS,
  progressTimeoutMs: config.OUTPUT_TIMEOUT_MS,
  maxAttempts: config.RETRY_MAX_ATTEMPTS,
  ...(config.RETRY_FREE_AFTER_MS === undefined
    ? {}
    : { retryFreeAfterMs: config.RETRY_FREE_AFTER_MS }),
  start: (input, onProgress) => {
    let outputs: ReturnType<typeof allocatePipelineOutputs>;
    try {
      outputs = allocatePipelineOutputs(config, input.publishUrl);
    } catch (error) {
      // Never log the URL itself: it contains the stream key.
      if (error instanceof Error && error.message === 'missing_output_url')
        log.error('worker_output_missing', { gameId: input.gameId });
      throw error;
    }
    return startPipeline(
      {
        gameId: input.gameId,
        pullUrl: input.readUrl,
        ...outputs,
        scoreFile,
        nvenc: false,
        encoder: config.ENCODER,
        decoderThreading: config.DECODER_THREADING,
        profile,
        ffmpegPath: config.FFMPEG_PATH,
        inputProbe: config.INPUT_PROBE,
        ...(config.INPUT_READ_TIMEOUT_MS === undefined
          ? {}
          : { inputReadTimeoutMs: config.INPUT_READ_TIMEOUT_MS }),
      },
      log,
      { onProgress, stopTimeoutMs: 1000 },
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
  await supervisor.close();
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
  scoreDelayMs: config.SCORE_DELAY_MS,
  inputProbe: config.INPUT_PROBE,
});
void poll();
void report();
