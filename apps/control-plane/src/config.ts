/** What the match and worker routes need from their host, the team object. */
export type RouteConfig = {
  /** The bearer token the match container's worker sends on /v1/worker. */
  workerToken: string;
  /** The worker and output every start command goes to. */
  workerId: string;
  outputId: string;
};
