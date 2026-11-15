import { createHash } from 'node:crypto';
import { pipelineReadKeyInput } from '@scorebug/protocol';
import type { Logger } from './logger.js';
import type { PipelineTerminal } from './pipeline.js';

/** Test-only logger scope. Its ordinal belongs to this worker, not supervisor attempts. */
export function createWorkerTerminalDiagnostics(
  log: Logger,
  flag: string | undefined,
  packetTimingFlag?: string,
  decodedGeometryFlag?: string,
) {
  const enabled = flag === '1';
  const packetTimingEnabled = enabled && packetTimingFlag === '1';
  const decodedGeometryEnabled = enabled && decodedGeometryFlag === '1';
  let ordinal = 0;
  return {
    enabled,
    packetTimingEnabled,
    decodedGeometryEnabled,
    scope(
      input: { gameId: string; generation: number },
      metadata?: Readonly<{ pipelineReadId?: string }>,
    ): {
      log: Logger;
      onTerminal?: (terminal: PipelineTerminal) => void;
    } {
      if (!enabled) return { log };
      if (!Number.isSafeInteger(ordinal + 1)) throw new RangeError('pipeline_ordinal_overflow');
      const hashInput = pipelineReadKeyInput(metadata?.pipelineReadId);
      const pipelineReadKey =
        hashInput === undefined
          ? undefined
          : createHash('sha256').update(hashInput, 'utf8').digest('hex');
      const scope = {
        gameId: input.gameId,
        generation: input.generation,
        pipelineOrdinal: ++ordinal,
        ...(pipelineReadKey === undefined ? {} : { pipelineReadKey }),
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
          decodedGeometry,
        }) => {
          scoped.info('worker_pipeline_terminal', {
            decodedVideo,
            telemetryEOF,
            encoderExit,
            outputProgress,
            ...(diagnostics ? { diagnostics } : {}),
          });
          if (decodedGeometryEnabled && decodedGeometry) {
            const {
              formatVersion,
              diagnosticOnly,
              timeBase,
              maximumRuns,
              ended,
              invalidReason,
              observedFrames,
              runs,
            } = decodedGeometry;
            // One bounded scalar record per contiguous run; never raw stderr or
            // unchecked metadata. Empty evidence still emits an invalid summary.
            for (let index = 0; index < Math.max(1, runs.length); index++) {
              const run = runs[index];
              scoped.info('worker_decoded_geometry', {
                formatVersion,
                diagnosticOnly,
                timeBase,
                maximumRuns,
                ended,
                invalidReason,
                observedFrames,
                runCount: runs.length,
                runIndex: run ? index : null,
                ...(run
                  ? {
                      width: run.width,
                      height: run.height,
                      firstOrdinal: run.firstOrdinal,
                      lastOrdinal: run.lastOrdinal,
                      firstPTS: run.firstPTS,
                      lastPTS: run.lastPTS,
                      frames: run.frames,
                      maximumPTSDelta: run.maximumPTSDelta,
                    }
                  : {}),
              });
            }
          }
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
                // Tail records include duration so a shutdown investigation can
                // compare track ends, independently from the startup prefix.
                for (let index = 0; index < (lane.last?.length ?? 0); index += 8) {
                  scoped.info('worker_packet_tail', {
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
                    packetCount: lane.packetCount,
                    firstPacketIndex: lane.packetCount - lane.last.length + index,
                    retainedPackets: lane.last.length,
                    packets: lane.last
                      .slice(index, index + 8)
                      .map(({ pts, ptsSeconds, dts, dtsSeconds, duration, durationSeconds }) => ({
                        pts,
                        ptsSeconds,
                        dts,
                        dtsSeconds,
                        duration,
                        durationSeconds,
                      })),
                  });
                }
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
