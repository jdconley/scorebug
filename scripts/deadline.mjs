/**
 * Run `operation(signal)` with a deadline that keeps Node's event loop alive.
 *
 * `AbortSignal.timeout()` uses an unref'd timer. If a fetch is left pending
 * with no live socket (for example a pooled keep-alive connection closed under
 * it while a container restarts), nothing keeps the process alive and Node
 * exits with code 13 ("unsettled top-level await") instead of timing out and
 * letting the caller retry. This timer is ref'd, covers the whole operation
 * including the body read, and rejects at the deadline even if the operation
 * ignores the signal.
 */
export async function withDeadline(ms, operation) {
  const controller = new AbortController();
  let timer;
  const expired = new Promise((_, reject) => {
    timer = setTimeout(() => {
      const error = new DOMException(`Timed out after ${ms} ms`, 'TimeoutError');
      controller.abort(error);
      reject(error);
    }, ms);
  });
  try {
    return await Promise.race([operation(controller.signal), expired]);
  } finally {
    clearTimeout(timer);
  }
}
