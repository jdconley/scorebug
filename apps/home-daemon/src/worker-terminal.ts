import type { Logger } from './logger.js';
import type { PipelineTerminal } from './pipeline.js';

/** Test-only logger scope. Its ordinal belongs to this worker, not supervisor attempts. */
export function createWorkerTerminalDiagnostics(
  log: Logger,
  flag: string | undefined,
  packetTimingFlag?: string,
) {
  const enabled = flag === '1';
  const packetTimingEnabled = enabled && packetTimingFlag === '1';
  let ordinal = 0;
  return {
    enabled,
    packetTimingEnabled,
    scope(input: { gameId: string; generation: number }): {
      log: Logger;
      onTerminal?: (terminal: PipelineTerminal) => void;
    } {
      if (!enabled) return { log };
      if (!Number.isSafeInteger(ordinal + 1)) throw new RangeError('pipeline_ordinal_overflow');
      const scope = {
        gameId: input.gameId,
        generation: input.generation,
        pipelineOrdinal: ++ordinal,
      };
      const scoped: Logger = {
        debug: (message, meta) => log.debug(message, { ...meta, ...scope }),
        info: (message, meta) => log.info(message, { ...meta, ...scope }),
        // The owned fixture drains stdout and deliberately ignores raw stderr.
        warn: (message, meta) => log.info(message, { ...meta, ...scope }),
        error: (message, meta) => log.info(message, { ...meta, ...scope }),
      };
      return {
        log: scoped,
        onTerminal: ({
          decodedVideo,
          telemetryEOF,
          encoderExit,
          outputProgress,
          diagnostics,
          packetTiming,
        }) => {
          scoped.info('worker_pipeline_terminal', {
            decodedVideo,
            telemetryEOF,
            encoderExit,
            outputProgress,
            ...(diagnostics ? { diagnostics } : {}),
          });
          if (packetTimingEnabled && packetTiming) {
            const {
              formatVersion,
              diagnosticOnly,
              maximumPacketsPerLane,
              ended,
              pipeError,
              drainTimedOut,
              incompleteLine,
              malformedRows,
              oversizedLines,
            } = packetTiming;
            for (const stage of ['demux', 'mux'] as const)
              for (const media of ['video', 'audio'] as const) {
                const lane = packetTiming[stage][media];
                // Separate bounded records retain lane order without claiming a
                // common interstream arrival order from FFmpeg's stderr threads.
                for (
                  let firstPacketIndex = 0;
                  firstPacketIndex < Math.max(1, lane.first.length);
                  firstPacketIndex += 8
                ) {
                  scoped.info('worker_packet_timing', {
                    formatVersion,
                    diagnosticOnly,
                    maximumPacketsPerLane,
                    ended,
                    pipeError,
                    drainTimedOut,
                    incompleteLine,
                    malformedRows,
                    oversizedLines,
                    stage,
                    media,
                    firstPacketIndex,
                    packetCount: lane.packetCount,
                    retainedPackets: lane.first.length,
                    packets: lane.first
                      .slice(firstPacketIndex, firstPacketIndex + 8)
                      .map(({ pts, ptsSeconds, dts, dtsSeconds }) => ({
                        pts,
                        ptsSeconds,
                        dts,
                        dtsSeconds,
                      })),
                  });
                }
              }
          }
        },
      };
    },
  };
}

/** Bounded shutdown flush only for diagnostic mode; no raw bytes are retained. */
export function flushWorkerDiagnostics(output: {
  write: (chunk: string, callback: () => void) => boolean;
}): Promise<void> {
  return new Promise((resolve) => {
    const done = () => {
      clearTimeout(timer);
      resolve();
    };
    const timer = setTimeout(done, 250);
    try {
      output.write('', done);
    } catch {
      done();
    }
  });
}
