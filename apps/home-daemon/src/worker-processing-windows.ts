import type { DecodedVideoSnapshot, DecodedVideoWindow } from '@scorebug/protocol';
import {
  workerProcessingInterval,
  type WorkerProcessingSnapshot,
  type WorkerProcessingInterval,
} from './worker-processing.js';
export type WorkerProcessingWindow = {
  scopeID: string;
  previousSequence: number;
  sequence: number;
  firstPTS: number;
  interval: WorkerProcessingInterval;
};
/** Pipeline-owned historical source windows. Report age and publication scope remain separate. */
export class WorkerProcessingWindows {
  private scopeID: string | undefined;
  private last: DecodedVideoWindow | undefined;
  private baseline: DecodedVideoWindow | undefined;
  private previous: DecodedVideoWindow | undefined;
  private frozen: WorkerProcessingWindow | undefined;
  private quarantined = false;
  observe(
    video: DecodedVideoSnapshot,
    snapshot: WorkerProcessingSnapshot,
  ): WorkerProcessingWindow | null {
    const { decoded, encoded } = snapshot;
    if (this.quarantined) return null;
    if (
      video.invalidReason !== null ||
      decoded.invalidReason !== null ||
      encoded.invalidReason !== null ||
      video.ended ||
      decoded.ended ||
      encoded.ended ||
      decoded.scopeID !== encoded.scopeID ||
      (this.scopeID !== undefined && this.scopeID !== decoded.scopeID)
    ) {
      this.quarantined = true;
      this.frozen = undefined;
      return null;
    }
    this.scopeID = decoded.scopeID;
    const window = video.completed;
    if (!window) {
      this.baseline = this.previous = this.frozen = undefined;
      return null;
    }
    if (
      this.last &&
      (window.sequence < this.last.sequence ||
        (window.sequence === this.last.sequence && !sameContents(window, this.last)))
    ) {
      this.quarantined = true;
      this.frozen = undefined;
      return null;
    }
    if (!this.last || window.sequence !== this.last.sequence) {
      this.previous = this.baseline;
      this.last = { ...window };
      this.frozen = undefined;
      this.baseline = eligible(window) ? { ...window } : undefined;
    }
    if (!eligible(window) || !this.previous || window.sequence !== this.previous.sequence + 1)
      return null;
    if (this.frozen) return structuredClone(this.frozen);
    const start = this.previous.lastPTS!,
      end = window.lastPTS!;
    const interval = workerProcessingInterval(snapshot, start, end);
    const anchor = decoded.frames.findIndex((frame) => frame.pts === start);
    if (
      !interval ||
      interval.decodedFrames !== window.freshFrames ||
      anchor < 0 ||
      decoded.frames[anchor + 1]?.pts !== window.firstPTS
    )
      return null;
    const result = {
      scopeID: this.scopeID,
      previousSequence: this.previous.sequence,
      sequence: window.sequence,
      firstPTS: window.firstPTS!,
      interval,
    };
    if (interval.submittedFrames > 0 && interval.pendingFrames === 0)
      this.frozen = structuredClone(result);
    return result;
  }
}
function eligible(window: DecodedVideoWindow): boolean {
  return (
    window.valid &&
    window.freshFrames > 0 &&
    window.duplicateFrames === 0 &&
    window.reorderedFrames === 0 &&
    window.firstPTS !== null &&
    window.lastPTS !== null
  );
}
function sameContents(a: DecodedVideoWindow, b: DecodedVideoWindow): boolean {
  return (
    [
      'durationMs',
      'firstPTS',
      'lastPTS',
      'freshFrames',
      'duplicateFrames',
      'reorderedFrames',
      'valid',
    ] as const
  ).every((key) => a[key] === b[key]);
}
