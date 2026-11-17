/** What the match and worker routes need from their host, the team object. */
export type RouteConfig = {
  /** The bearer token the match container's worker sends on /v1/worker. */
  workerToken: string;
  /** The worker and output a start command goes to when it names neither. */
  workerId: string;
  outputId: string;
};
