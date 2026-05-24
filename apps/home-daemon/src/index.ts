import type { HomeMessage } from '@scorebug/protocol';
import { ControlPlaneClient } from './client.js';
import { loadConfig } from './config.js';
import { createLogger } from './logger.js';
import { renderOverlayLine, placeholderLine } from './overlay-text.js';
import { startPipeline, type PipelineHandle } from './pipeline.js';
import { atomicWrite, scoreFilePath } from './score-file.js';

const config = loadConfig();
const log = createLogger(config.LOG_LEVEL);
const scoreFile = scoreFilePath(config.SCORE_DIR);

let pipeline: PipelineHandle | undefined;
let teamsCache: { home: { shortName: string; name: string; color: string }; away: { shortName: string; name: string; color: string } } | undefined;

await atomicWrite(scoreFile, placeholderLine());

const client: ControlPlaneClient = new ControlPlaneClient(config.CONTROL_PLANE_WS, config.HOME_TOKEN, log, {
  onMessage: async (msg: HomeMessage) => {
    switch (msg.type) {
      case 'start_game': {
        if (pipeline) {
          log.warn('start_received_while_running', { gameId: msg.gameId });
          pipeline.stop();
          await pipeline.waitExit();
          pipeline = undefined;
        }
        teamsCache = msg.teams;
        await atomicWrite(scoreFile, placeholderLine());
        pipeline = startPipeline(
          {
            gameId: msg.gameId,
            pullUrl: msg.pullUrl,
            publishUrl: `${config.RTMP_TARGET}/${msg.youtubeStreamKey}`,
            scoreFile,
            nvenc: config.NVENC_ENABLED,
          },
          log,
        );
        client.report({ type: 'pipeline_started', gameId: msg.gameId });
        // When ffmpeg exits unexpectedly, report it.
        pipeline.waitExit().then(({ code, signal }) => {
          if (pipeline?.spec.gameId === msg.gameId) {
            client.report({
              type: 'pipeline_stopped',
              gameId: msg.gameId,
              reason: code === 0 ? 'requested' : 'crashed',
            });
            log.info('pipeline_cleared', { gameId: msg.gameId, code, signal });
            pipeline = undefined;
          }
        });
        break;
      }
      case 'end_game': {
        if (pipeline?.spec.gameId === msg.gameId) {
          pipeline.stop();
          await pipeline.waitExit();
          pipeline = undefined;
        } else {
          log.warn('end_received_for_unknown_game', { gameId: msg.gameId });
        }
        teamsCache = undefined;
        await atomicWrite(scoreFile, placeholderLine());
        break;
      }
      case 'score_update': {
        if (!teamsCache) {
          log.warn('score_update_without_teams', { gameId: msg.gameId });
          return;
        }
        await atomicWrite(scoreFile, renderOverlayLine(teamsCache.home, teamsCache.away, msg.score));
        break;
      }
      case 'callout': {
        // v1 ignores callouts (Smelter + Rive comes in v2). Log so the wire
        // shape is exercised; no overlay reaction yet.
        log.info('callout_received', { gameId: msg.gameId, kind: msg.event.kind });
        break;
      }
    }
  },
});

client.start();

const shutdown = async (sig: string) => {
  log.info('shutdown_signal', { sig });
  if (pipeline) {
    pipeline.stop();
    await pipeline.waitExit();
  }
  client.stop();
  process.exit(0);
};

process.on('SIGINT', () => void shutdown('SIGINT'));
process.on('SIGTERM', () => void shutdown('SIGTERM'));
