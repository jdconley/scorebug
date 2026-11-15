import { mkdirSync, mkdtempSync } from 'node:fs';
import { join, resolve } from 'node:path';
import type { Config } from './config.js';
import type { PipelineSpec } from './pipeline.js';

/** Called once per pipeline attempt, including retries; old recordings are retained. */
export function allocatePipelineOutputs(
  config: Pick<Config, 'OUTPUT_MODE' | 'OUTPUT_URL' | 'OUTPUT_RECORDING_DIR'>,
): Pick<PipelineSpec, 'publishUrl' | 'recordingPath'> {
  const output: Pick<PipelineSpec, 'publishUrl' | 'recordingPath'> = {};
  if (config.OUTPUT_MODE !== 'record') output.publishUrl = config.OUTPUT_URL!;
  if (config.OUTPUT_MODE !== 'rtmp') {
    const root = resolve(config.OUTPUT_RECORDING_DIR!);
    mkdirSync(root, { recursive: true, mode: 0o700 });
    // mkdtemp creates an exclusive 0700 directory, so a retry cannot overwrite
    // an earlier attempt even though tee slave muxers do not honor FFmpeg -n.
    output.recordingPath = join(mkdtempSync(join(root, 'attempt-')), 'overlay.mp4');
  }
  return output;
}
