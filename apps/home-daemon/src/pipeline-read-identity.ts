import { randomUUID } from 'node:crypto';

const productionRead = /^read:scorebug-[0-9a-f]{16}-[0-9a-f]{32}$/;

/** Bind one process read without changing unsupported media URLs or exposing credentials. */
export function identifyPipelineRead(readUrl: string): {
  readUrl: string;
  pipelineReadId?: string;
} {
  try {
    // URL parsing silently removes raw controls; do not identify a repaired URL.
    if (readUrl !== readUrl.trim() || /[\u0000-\u001f\u007f]/.test(readUrl)) return { readUrl };
    const url = new URL(readUrl);
    const streamIds = url.searchParams.getAll('streamid');
    const streamId = streamIds[0];
    if (
      url.protocol !== 'srt:' ||
      !url.hostname ||
      streamIds.length !== 1 ||
      streamId?.length !== 63 ||
      !productionRead.test(streamId)
    )
      return { readUrl };
    const pipelineReadId = randomUUID();
    url.searchParams.set('streamid', `${streamId}:sbw1=${pipelineReadId}`);
    return { readUrl: url.toString(), pipelineReadId };
  } catch {
    return { readUrl };
  }
}
