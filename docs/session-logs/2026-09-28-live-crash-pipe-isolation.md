# September 28 — live crash after guardian pipe isolation

Starting987af6e, clean. Previous goal turn delivered a hands-on simulator launcher.
No lab/test jobs carried over; its three manual simulators remain idle/booted.

Saved crash diagnostics lack incoming/mux packet timing at the crash boundary.
TSWriter emits ongoing compressed A/V on arrival, but this alone does not prove
a cause. No speculative queue, encoder setting or timing limit was changed.

One targeted70s integration checks production guardian change723b8f5:
`node scripts/test-headless-streaming.mjs --host 192.168.1.130 --source
/Users/jd/.codex/worktrees/scorebug-local-validation/artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov
--duration 70 --quality 1080 --timing-audit off --worker-encoder software
--worker-crash-after 15`, with scoped Xcode26.2 DEVELOPER_DIR.
Artifact`headless-native-8guvcT`, lab`device-lab-xVZMvn`;45847 joined0.
Reused native export bundle via publisher-blackhole-20260928/export-current.py,
then interrupted-tail-20260928/verify-crash-media.py;22561 joined0.

Worker absent15.235s; same publisher/broadcast, oneStart/Stop. Archive37segments,
2,125consecutive frames0–2124, gap-free audio. Both output sequences62–443 then
962–2104 match:518missing live frames/17.2667s outage. All five MP4s fully decode,
consecutive source IDs and gap-free audio within each session. Archive continues
20frames beyond final live video. A/V ends: archive13.33ms, interrupted mock106.24ms/
proxy107.24ms, recovered mock37.11ms/proxy37.44ms. All cleanup failures empty.

worker-crash-acceptance.json binds configuration, current source hash at analysis,
diagnostics, verifier/guardian, restart/cleanup and media hashes. First binding
attempt expected a source-binding.json that this harness does not create; it
failed before writing anything. Corrected bind-acceptance.py uses actual config
and explicitly labels source hash at analysis. No capture was repeated.

The107ms tail is effectively unchanged. Keep the pipe ownership fix, but do not
claim it solved A/V tails. This is not an isolated causal experiment across all
scheduling/load differences. Further investigation needs live boundary timing;
unchanged captures or guardian timeout changes are not justified. No new UI,
hardware, full-suite or soak tests. No production code changed this session.
All lab/test jobs terminal. General tail/backend/full-match/hardware gates remain.
