/** Public diagnostic correlation only; the private read UUID is never published.
 * Hash this exact UTF-8 input with SHA-256 at the platform boundary. */
export function pipelineReadKeyInput(id: unknown): string | undefined {
  if (
    typeof id !== 'string' ||
    id.length !== 36 ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id)
  )
    return undefined;
  return 'scorebug-pipeline-read-v1:' + id;
}
