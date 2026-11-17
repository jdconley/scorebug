/** Exact bounded-credit rule used by the live FFmpeg select filter.
 * Both branches use 1/90000 PTS. This predicts deliberate cap decisions; it
 * is not an observation of CPU use or downstream completion. */
export function frameRateCapFilter(fps: number): string {
  return `select='st(0,if(isnan(prev_t),2,min(2,ld(0)+max(0,t-ld(1))*${fps})));st(1,if(isnan(prev_t),t,max(ld(1),t)));if(isnan(prev_selected_t)+gt(t,prev_selected_t),if(gte(ld(0),1-1.5*TB*${fps}),st(0,max(0,ld(0)-1))*0+1,0),0)'`;
}
