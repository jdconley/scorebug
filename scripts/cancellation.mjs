// Let each bounded Docker operation settle before teardown, so a delayed create
// cannot race cleanup. Signals during teardown must not interrupt that teardown.
export function cancellation() {
  let interrupted = false;
  for (const signal of ['SIGINT', 'SIGTERM']) {
    process.on(signal, () => {
      interrupted = true;
      process.exitCode = 1;
    });
  }
  return () => {
    if (interrupted) throw new Error('Validation interrupted; cleaning up owned resources');
  };
}
