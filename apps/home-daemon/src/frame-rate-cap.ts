/** Exact bounded-credit rule used by the live FFmpeg select filter.
 * Both branches use 1/90000 PTS. This predicts deliberate cap decisions; it
 * is not an observation of CPU use or downstream completion. */
export function frameRateCapFilter(fps: number): string {
  return `select='st(0,if(isnan(prev_t),2,min(2,ld(0)+max(0,t-ld(1))*${fps})));st(1,if(isnan(prev_t),t,max(ld(1),t)));if(isnan(prev_selected_t)+gt(t,prev_selected_t),if(gte(ld(0),1-1.5*TB*${fps}),st(0,max(0,ld(0)-1))*0+1,0),0)'`;
}
export class FrameRateCap {
  private credits = 2;
  private highestTime: number | undefined;
  private selectedTime: number | undefined;
  constructor(private readonly fps: number) {
    if (!Number.isInteger(fps) || fps <= 0 || fps > 240) throw new RangeError('Invalid cap rate');
  }
  select(pts: number): boolean {
    const time = pts / 90000;
    if (this.highestTime !== undefined)
      this.credits = Math.min(2, this.credits + Math.max(0, time - this.highestTime) * this.fps);
    this.highestTime = this.highestTime === undefined ? time : Math.max(this.highestTime, time);
    if (this.selectedTime !== undefined && time <= this.selectedTime) return false;
    if (this.credits < 1 - (1.5 / 90000) * this.fps) return false;
    this.credits = Math.max(0, this.credits - 1);
    this.selectedTime = time;
    return true;
  }
}
