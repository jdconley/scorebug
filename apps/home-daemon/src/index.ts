import { loadConfig, videoProfiles } from './config.js';
import { createLogger } from './logger.js';
import { startPipeline } from './pipeline.js';
import { scoreFilePath } from './score-file.js';
import { WorkerClient } from './worker-client.js';
import { WorkerSupervisor } from './supervisor.js';
import { WorkerReporter } from './worker-reporter.js';

const config = loadConfig();
const log = createLogger(config.LOG_LEVEL);
const scoreFile = scoreFilePath(config.SCORE_DIR);
const client = new WorkerClient(config.CONTROL_PLANE_URL, config.HOME_TOKEN, config.WORKER_ID);
const reporter = new WorkerReporter(config.CONTROL_PLANE_URL, config.HOME_TOKEN, config.WORKER_ID);
const supervisor = new WorkerSupervisor({
  load: () => client.load(),
  scoreFile,
  outputId: config.OUTPUT_ID,
  onState: (state) => log.info('worker_state', state),
  start: (input, onProgress) =>
    startPipeline(
      {
        gameId: input.gameId,
        pullUrl: input.readUrl,
        publishUrl: config.OUTPUT_URL,
        scoreFile,
        nvenc: false,
        encoder: config.ENCODER,
        profile: videoProfiles[config.VIDEO_PROFILE],
        ffmpegPath: config.FFMPEG_PATH,
        fontPath: config.FONT_PATH,
      },
      log,
      { onProgress, stopTimeoutMs: 1000 },
    ),
});
let stopping = false;
let timer: ReturnType<typeof setTimeout> | undefined;
let reportTimer: ReturnType<typeof setTimeout> | undefined;
let reportingFailed = false;
const report = async () => {
  const observation = supervisor.observation();
  if (observation) {
    try {
      await reporter.report(observation);
      if (reportingFailed) log.info('worker_reporting_recovered');
      reportingFailed = false;
    } catch {
      if (!reportingFailed) log.warn('worker_reporting_unavailable');
      reportingFailed = true;
    }
  }
  if (!stopping) reportTimer = setTimeout(() => void report(), 1000);
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
  encoder: config.ENCODER,
  profile: config.VIDEO_PROFILE,
});
void poll();
void report();
