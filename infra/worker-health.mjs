// Worker health probe for container healthchecks and install.sh.
//
// Exit 0 when the control plane accepts this worker's CONTROL_PLANE_URL,
// HOME_TOKEN and WORKER_ID. Prints one status line either way. It reads the
// worker's own environment and never prints the token. It does not prove that a
// broadcast is flowing; use the phone app's worker status for that.
const url = process.env.CONTROL_PLANE_URL;
const token = process.env.HOME_TOKEN;
const workerId = process.env.WORKER_ID;
if (!url || !token || !workerId) {
  console.log('worker_health=fail reason=missing_config');
  process.exit(1);
}
try {
  const response = await fetch(
    new URL(`/v1/worker/snapshot?workerId=${encodeURIComponent(workerId)}`, url),
    { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(4000) },
  );
  if (!response.ok) {
    console.log(`worker_health=fail reason=http_${response.status} worker=${workerId}`);
    process.exit(1);
  }
  const body = await response.json();
  const assignment = body.assignment ? `match=${body.assignment.match?.id ?? 'unknown'}` : 'idle';
  console.log(`worker_health=ok worker=${workerId} ${assignment}`);
} catch (error) {
  const reason = error?.cause?.code ?? (error?.name === 'TimeoutError' ? 'timeout' : 'unreachable');
  console.log(`worker_health=fail reason=${reason} url=${new URL(url).origin}`);
  process.exit(1);
}
