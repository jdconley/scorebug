# Combined client network outage — September 28

Starting ba0c570, authoritative local-validation checkout. Simulator-first,
focused checks only. No production behavior changed, hardware, agents or broad
suite. Reused all previous native scoring/UI/UHD/media results.

Added a private TCP forwarding fixture that closes existing connections and rejects
new connections while blocked. It streams with backpressure, bounds forwarded
connections to 64, never logs payloads/credentials, joins owned sockets on shutdown,
and treats unexpected fixture errors as invalid evidence. Worker/API backend access
remains direct; only the native client's configured endpoint is proxied. Combined
with the existing bidirectional UDP blackout through `--client-outage-seconds`.

Two real-socket tests pass in 0.1 seconds: existing connections drop, blocked API
requests fail while direct backend remains reachable, access restores, cleanup joins;
invalid endpoints reject before allocation. First check failed because the fixture
was not yet implemented. Formatting and diff checks pass. No production test rerun.

## Targeted result

headless-native-KJYNvL; device-lab-vPtkAp. Source revision/file hashes retained in
source-binding.json. Capture handle 53810 and export/media handle 9029 joined 0;
cleanup empty. No active processes from this work.

Command: scoped Xcode 26.2; `node scripts/test-headless-streaming.mjs
--host 192.168.1.130 --source <checkout>/artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov
--duration 90 --quality 1080 --timing-audit off --worker-encoder software
--disconnect-after 15 --client-outage-seconds 25`.

Actual API blackout 25.001 seconds: 366 connections rejected, forwarded/returned
byte counters unchanged. UDP drops 510 forward/669 reverse packets, no socket
sends during blackout. All fixture errors empty; sockets/queues joined.
Observed lifecycle: publishing at 0, failed at 20, publishing at 40 seconds.
No intervening starting attempt observed while API is offline; retained focused
reconnect tests cover fresh-control/ownership requirements. One recording and
generation 1 throughout, one Start and one final Stop. Recording/publishing active
at end (91 seconds).

Native export reused the current bundle without another build. 47 segment metadata
and payload hashes verified. Archive 2,727 consecutive 1080p30 frames (0–2726),
gap-free audio. Both outputs match source IDs 62–451 then 1269–2706. All five files
fully decode, no within-session frame identity/audio timestamp gaps, maximum frame
gaps 34 ms, A/V ends within 49 ms. The archive continues 20 frames beyond live output.

**Live interruption: 817 missing source frames, 27.233 seconds.** This includes
network loss plus recovery; it is not gap-free streaming or physical radio proof.
Static overlay pipeline is retained; changing-score/Watch acceptance is separate.

`client-network-acceptance.json` binds media, fixture counters, lifecycle, source,
verifier and cleanup hashes. `reconnect-media/result.json` has per-file results.
Verifier in artifacts/qa/client-outage-20260928 adapts the retained outage checker;
no extra capture or decode rerun. Per-hop UDP snapshot still correctly describes
its own unaffected API scope; the aggregate report describes the combined fault.

Next: remaining intermittent loss and severe-congestion behavior, abrupt output
tails and sustained backend qualification. Do not repeat completed outage/UHD runs
without a relevant production change. Current TODOs remain in the delivery plan.
