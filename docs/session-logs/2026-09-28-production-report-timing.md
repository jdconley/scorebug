# Production control-report timing

Starting point: `9d93278`, local-validation worktree. Simulator-first; no agents,
hardware, pushes or real broadcasts. The previous turn made progress by adding the
headless native harness and reproducing the UHD reset outside simulator UI.

## Evidence and decision

`headless-native-qfiBCM` reached720p but reset during probation when a worker-status
HTTP request took168ms. Conservative report age was289.66ms (119ms server age plus
request and2.63ms local residence). Another request took382ms and total age458ms.
Native probe reads were negligible. This is control-report jitter, not affirmative
frame-loss evidence; the existing250ms report-age contract rejects it.

Add immutable `broadcast-reliability3000-v3`: one-second maximum cadence/delivery
report age,3000ms decoder delivery budget,4250ms capture evaluation age (3s media +1s report +250ms scheduling). Production
selects v3. Older profile IDs retain their original250ms allowance. One second is a
bounded product choice allowing margin over observed HTTP jitter, not a claimed
platform standard. No extra media buffering is inserted; deadline classification waits for the bounded report allowance. Unknown/expired reports
still reject; report timestamps are never renewed. Decoder stall threshold remains
one second, and native congestion/pressure, source-loss/fresh-frame limits, candidate
expiry, receipt/ownership and archive independence remain enforced.

The setting is propagated through Core failure/advice deadlines, native cadence
and delivery admission, the continuous delivery consumer, audit contracts and host
validators. Current diagnostics expose the report budget. The cadence audit now
receives the actual driver's profile instead of defaulting production to strict.

Also fix an acceptance omission: quality2160 selected4K recording and a UHD worker,
but the shared ladder workflow returned after1080 confirmation. It now requires
2160p/24Mbps acknowledgment and probation confirmation before scoring/stop/export.

## Focused validation

- Added regression using the actual289.66ms/457.64ms delays and the1second boundary.
  Initial Core run fails because v2 is absent; after implementation,22 selected
  Core tests pass. Wrong ownership and age>1second reject; old profiles still reject
  the measured delays. Media/candidate/local-pressure bounds remain covered.
- Four selected Mac model checks pass: delayed HTTP report preserves probation,
  expired report triggers rollback, strict rejection audit remains intact,
  production selects matching timing, and every profile exports its exact contract.
  (The production-selection and contract checks are separate methods; four total.)
- Selected host timing/audit validators:75tests pass; affected cadence/delivery and
  ordinary evidence validators:113tests pass. Runtime is well under a second each.
- Logs retained in `artifacts/qa/production-report-timing-20260928`.

## Integration checkpoint

The first simulator run `ordinary-native-ClWHlf` was stopped early after detecting
an inconsistent scheduling allowance: the delivery scheduler waits media budget
plus maximum report age before classification, so3500ms could never admit a window
scheduled at4000ms. Its candidate contract ID was v2; that aborted contract is not
reused. Final v3 uses4250ms evaluation allowance without changing the3s media deadline.
Cleanup passes with no remaining owned resources. Added a regression using the
actual delivery scheduler across all timing profiles (with regular foreground ticks;
an initial test fixture incorrectly jumped over the6s profile's5s suspension guard).

Final disposable simulator checkpoint `ordinary-native-z1va0e`, lab `device-lab-vgxwUF`,
exec55738 joined1; cleanup `[]`. Final profile v3 confirms360p and720p without the
previous cadence rollback.1080 acknowledgment comes just after its150s gate expires;
4K remains unqualified. Do not rerun the same full workflow to wait longer.

Saved candidate evidence identifies slower headroom admission: first1080 candidate
cost7,184,880bps versus7,697,885bps delivered padding; retry cost7,152,806 versus
8,840,506 padding (below1.25×cost). Another candidate fails during candidateJoined.
A later candidate qualifies: cost6,976,744 versus9,170,547 padding, and1080 is actually
acknowledged. Nominal requested padding exceeds receiver-delivered pacing; isolate
sender pacing/headroom in a short focused native check before changing probe rates,
protocol or admission criteria. Do not assume the cause is network or timer loss
without measuring the native path.

The run's export error was also masked by the test's terminal90s global deadline:
its UHD180s export wait was clipped to roughly60s after stop/navigation. Changed
only the UHD terminal allowance to240s (normal90s unchanged). No app export timer,
recording540s bound or adaptive gate changed. This small harness fix is not yet
runtime-verified. Raw archive and two prepared MP4s (~1.24GB each) were preserved;
there is no completed native export acceptance. Attachments contain the original
`initial-1080-increase` failure as well as the later clipped export failure.

Final focused checks pass: actual delivery scheduler/production selection/delayed
request probation (3model tests),9Core timing tests and75host timing tests. Earlier
strict/cadence/delivery checks remain retained. Full simulator build passes. All
jobs joined; no owned simulator/lab remains. No hardware work or full offline media
analysis was run on this failed checkpoint.

Next: diagnose UHD padding throughput using a short SDK/headless native check;
retain the demonstrated timing fix and confirmed720p result. The simulator4K gate
now genuinely requires2160p acknowledgment/probation. Qualify full climb, final
export and independent media only after the new throughput regression passes.
