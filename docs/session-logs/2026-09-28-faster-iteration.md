# September 28 — faster iteration

Starting checkout: `codex/local-validation`, `17b326c`, clean.

The user explicitly prioritized faster implementation and simulator feature
completion over repeated tests and hardware work. Reviewed the current plan,
retained acceptance paths, existing runners and their build/cleanup behavior.
No app, simulator, hardware, media capture or container test was started.

The local functional vertical already has retained results: two native phones,
Watch scoring through real HTTP, clean recording/export, adaptive SRT, score
changes at the proxy, mock RTMP MP4 and optional proxy MP4. These are incremental
results, not a single new all-features run. WatchConnectivity, simulator UHD and
severe congestion, colocated VideoToolbox/probe loss, and abrupt output tails
remain explicitly limited or unresolved.

Trimmed the plan's historical completed-run details into a feature checklist;
existing acceptance/session files retain the detailed measurements. Kept every
open delivery gate, distinguishing local defects from later endurance, hardware,
external deployment and hosted CI qualification. Added `docs/fast-iteration.md`
using existing commands and replaced README's default broad test list with the
focused workflow. No production code or thresholds changed.

Validation: reviewed documentation diff, verified new relative file links and the
three referenced key acceptance artifacts exist; `git diff --check` passes.
No application test is warranted for these documentation-only changes.
No jobs remain active. Next: inspect saved crash-tail evidence and production
output ownership/drain before selecting a targeted change and check. Do not
resume physical tests or repeat the passed sustained UHD run.
