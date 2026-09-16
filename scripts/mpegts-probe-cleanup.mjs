import { requestProbeStop, stopProbeProcess } from './capacity-probe-process.mjs';

// Persistence can fail (including ENOSPC) only after all resource joins are attempted.
export async function closeMPEGTSProbe(owners, proxy, persist) {
  const failures = [];
  for (const owner of owners) requestProbeStop(owner);
  for (const owner of owners)
    try {
      await stopProbeProcess(owner);
    } catch (e) {
      failures.push(String(e));
    }
  if (proxy)
    try {
      await proxy.close();
    } catch (e) {
      failures.push(String(e));
    }
  try {
    await persist();
  } catch (e) {
    failures.push(String(e));
  }
  return failures;
}
