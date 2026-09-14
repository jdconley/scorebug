import { loadConfig, videoProfiles } from './config.js';
import { createLogger } from './logger.js';
import { startPipeline } from './pipeline.js';
import { scoreFilePath } from './score-file.js';
import { WorkerClient } from './worker-client.js';
import { WorkerSupervisor } from './supervisor.js';

const config = loadConfig();
const log = createLogger(config.LOG_LEVEL);
const scoreFile = scoreFilePath(config.SCORE_DIR);
const client = new WorkerClient(config.CONTROL_PLANE_URL, config.HOME_TOKEN, config.WORKER_ID);
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
