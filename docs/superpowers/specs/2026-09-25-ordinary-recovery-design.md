# Ordinary production congestion and recovery design

## Purpose

Qualify the user's start-low, increase, fall back and recover behavior through the
normal native publishing controller, while retaining independent clean local A/V,
native scoring, proxy overlay, mock RTMP MP4 and optional proxy MP4. Existing
laboratory evidence remains separate. This work is authorized by the ongoing
implementation/verification request and autonomous-work instruction.

## Approach

Use a publisher-only UDP impairment route delivered by the ordinary control
plane. The worker reads directly from the relay. This preserves actual SRT
traffic, native quality decisions and normal API credentials while isolating the
upload bottleneck. A fixed-time fault is unsuitable because trial completion is
variable. The old laboratory URL selector is unsuitable because it changes the
app route being qualified. Neither alternative is used for this qualification.

Optional server settings `INGEST_PUBLISH_HOST` and `INGEST_PUBLISH_PORT` are a
pair. If absent, publishing uses the existing ingest address. If present, only
native publish grants use that endpoint; worker read grants, relay management,
path identity, generation and publish/read passphrases remain unchanged. Reject
partial or malformed overrides. Do not accept URLs, credentials, path, query or
fragments in the host. Support DNS, IPv4 and raw IPv6 consistently with ingest
URL construction. These are ordinary deployment settings, useful where upload
and internal read addresses differ; they do not enable controller test behavior.

The local test proxy retains loopback frontend binding. Its optional receiver
address may reach this Mac's LAN relay. An explicit event-driven mode, exclusive
with scheduled phases, allows one declared finite phase and one restoration.
The test controller starts the fault only after observed acknowledgment and
confirmation of360p; restoration follows observed acknowledgment of240p. Private
XCTest control requests alter the network fixture only. The app receives just
its existing file-source selection, no injected measurements or quality commands.

## Test contract

- Normal initial profile is240p30/350kbps. A native point updates both live overlays.
- Preserve the150second initial increase gate and normal10second healthy trial
  confirmation. Expose bounded current owner-scoped confirmation evidence if
  necessary; acknowledgment alone does not establish confirmation.
- Apply a predeclared750kbps forward-only cap, no injected loss/delay. Prove actual
  offered demand and token denial/queue pressure; the rate alone is not evidence
  of congestion. Reverse traffic and the worker-reader route stay unaffected.
- Observe actual minimum acknowledgment within a bounded fault interval, then
  restore capacity. Require a fresh successful measured increase under unchanged
  production freshness, delivery, backoff and resource limits. No restart may
  substitute for adaptation; bind all transitions to the same publishing scope.
- Retain exact requested/applied monotonic phase boundaries, bounded queue
  snapshots, complete conservation and rate ledger. Evidence overflow is a
  failed qualification, not permission to omit history.
- Use a separately prepared600second finite representative source with frame
  identities and verified A/V. Never loop or lengthen adaptive deadlines to pass.
- Finish with live hold, stop streaming, continued local recording and native
  stop/export. Join all owned runners/proxy/lab resources before media analysis.
- Fully decode all three outputs. Verify source identities, freshness, A/V
  continuity and sampled waveform alignment across phases, changing live scores,
  clean archive and archive continuation. Preserve impaired-phase failures.

The older21ms live-audio gap and incomplete historical audit remain open until
independently resolved. A new ordinary success would not erase those failures.
Physical paired acceptance, wider profiles, full-match operation and remote
workers remain separate delivery gates.

## Implementation order

1. Add and verify ordinary publisher-only endpoint configuration and grant wiring.
2. Add bounded event-driven UDP impairment and ordinary lab ownership/cleanup.
3. Add current trial confirmation evidence and the native recovery test lane.
4. Qualify complete transport evidence and all three recordings, diagnose any
   actual failures, and review the resulting implementation before hardware use.
