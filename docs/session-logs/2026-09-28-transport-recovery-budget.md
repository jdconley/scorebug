# September 28: transport recovery budget

Starting revision `bcd626a`, `codex/local-validation`. Prior goal turn made concrete
progress on source interruption, actual Mac service operation and consolidated
acceptance. Current focus is the remaining severe-congestion live-media failure.
Hardware stays deferred. No new agents or full regression suite.

## Evidence and candidate

Existing `ordinary-native-IZI72F/collapse-packet-analysis.json` reports maximum
observed network queue residence2566.6ms, first NAK3692.7ms after collapse,89unique
dropped sequences and zero retried or later forwarded dropped sequences. Publishing
SRT delay was700ms. The analysis is header-only, not proof of which encrypted packet
contained a keyframe or exactly when the sender retired it. The hypothesis is that
loss reports arrive beyond the usable repair horizon; changing the GOP does not
address that mismatch. Earlier sender warning improves acknowledgment to856–887ms
but still loses live A/V. Archive remains continuous.

Test one coherent reliability candidate: explicit6000ms SRT publishing recovery,
versioned8000ms capture-to-decoder contract,8500ms completed capture-window evaluation
allowance. Six seconds covers the measured queued/feedback delay plus repair time
for the approximately60KB lost burst while minimum-quality media continues. These
are experimental project values, not published platform defaults or a guarantee.
More recovery time adds startup/broadcast latency; measure the tradeoff before
calling it a production policy. Report freshness(2s), cadence report age(250ms),
decoder stall threshold(1s), source loss/queue/thermal handling and archive stay unchanged.
Original strict1500/2000/3000 contracts and failed outputs remain intact.

The API and ordinary lab now allow an explicit peer-latency bound up to6000ms;
API default stays unset during this experiment. The production app factory selects
the candidate timing contract for the ordinary run; no native fixture route is enabled.
Do not keep an unqualified production timing switch if the test fails.

Focused checks:83host timing/audit/options,84API config/ingest and8Swift timing tests
pass. Incremental native build passes. One running workflow:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer \
node scripts/test-ordinary-native-app.mjs --host 192.168.1.130 \
  --source /Users/jd/.codex/worktrees/scorebug-local-validation/artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov \
  --lane recovery720 --publish-peer-latency-ms 6000
```

Artifact `ordinary-native-JXNYVG`, lab `device-lab-HFmlBB`. Result pending; do not
infer success from the build or a timing allowance. Save actual native negotiated
delay, application transitions, retransmission behavior and decoded media; retain
original strict media assertions. No repeats without new evidence.

## First outcomes and coherent bound

`ordinary-native-JXNYVG` failed only the initial-minimum gate, before any bandwidth
fault. Its native diagnostics actually show publishing, authoritative source owner
and policyReady; the UI guard hardcoded a5second source-age ceiling. Fixed native
and independent host guards to recognize exact versioned timing headers; old/absent
profiles retain their old bound, malformed/mismatched headers reject. Focused guard
checks cover valid delayed source, stale source and altered metadata. One unrelated
negative option case still expected2001rejected; corrected it to the candidate's
new upper-bound+1. The initial failed check log is retained.

The retry `ordinary-native-aFBbhR` reached initial-minimum but could not produce an
upward admission. Code inspection establishes a second constraint: candidate raw
measurement spans4seconds with a2second post-measurement authority limit and requires
an overlapping healthy source interval. Six seconds of SRT delay plus decode overhead
cannot supply that interval before expiry. Stopped only its verified runner PID68341
withSIGINT, joined session47318; artifacts/app-data preserved,cleanup failures[].
Do not widen candidate expiry or weaken source overlap to make the experiment pass.
Saved the complete first candidate diff as`artifacts/qa/recovery-budget-6000-candidate.patch`.

The replacement candidate uses4000ms publishing recovery and the explicit
`broadcast-reliability6000-v1` capture-to-decoder contract(6500ms capture-window
allowance). API/lab maximum override is now4000ms, default still unset. It keeps the
same4second measurement/2second expiry and fresh-report/stall checks.113host timing,
options/native-guard/independent-recovery checks and84APIchecks pass. No further broad
suite. Current single run is recorded in`artifacts/qa/reliability-budget-20260928-four-second.log`.

## Final result and restoration

`ordinary-native-C8IXkq`, lab`device-lab-AVMGOB`, fails the150second initial360increase
gate. No bandwidth constraint was applied.71native snapshots preserve36source-overlap
deferrals and30source-age deferrals; three measurement failures. A representative
fresh source has6.3746seconds capture age but only1.1959seconds report age, so decoded
transport lag is about5.18seconds. Source/candidate overlap is false. This confirms
that increasing SRT delay alone is incompatible with the present admission schedule.
Artifacts and exports preserved; runner session38593 joined exit1,cleanup failures[].
All three native/lab jobs and all focused-check jobs are terminal. No live owned jobs.

Restored every timing-profile, API bound/default, diagnostic guard and option change
to its exact`bcd626a`content. The two candidate diffs and immutable native run patches
remain in artifacts. Current production decoder profile stays3000ms; publishing
peer override remains120–2000ms and unset by default. No failed result relabelled,
no deadline/authority relaxation retained, no further parameter-only rerun.

The independently useful fix retained: `SRTStopPolicy`'s default total shutdown
budget is6seconds instead of3. The already-supported2000ms peer delay plus500ms
of downstream drain and800ms encoder finish needs3.3seconds; the old default closes
early. The stop still exits promptly after actual negotiated delay/queue clearance,
shares one finite deadline, handles cancellation/failed health, and obeys explicit
shorter caller budgets.11focused stop tests pass, including that boundary, explicit
3second rejection and unchanged660ms completion for a120ms peer. This is model/library
validation; no new physical or end-to-end stop qualification claimed. Active native
captures had already built before this fix, so do not credit them with the new drain.

## Next implementation, not another latency knob

Investigate production candidate scheduling against source report phase. Current
production waits for a newly completed source window immediately before starting
its4second candidate measurement. Source reports arrive every5seconds. With the
measured5.18second decode lag, the next report's source interval ends before that
measurement starts; the following report arrives after its2second expiry. This
creates a repeatable phase mismatch even when transport and report health are good.
The live snapshot evidence corroborates that mechanism.

A bounded scheduling change can preserve all existing authority checks: use the
actual fresh source interval duration/observed time to place the candidate measurement
so a future source interval can overlap before expiry. This is scheduling only,
never predicted delivery or admission credit. Keep native probe renewal/cancellation,
actual source overlap, unchanged4second measured cost and2second expiry. Short-lag
production and fixed laboratory ordering should remain unchanged. Derive any wait
from the current source window and cap it at one source interval; do not add arbitrary
long holds or increase retained audit limits. For period5, measured lag5.18 and a
4+2second measurement/expiry span, starting roughly4.4seconds after the fresh report
places a candidate around the following report boundary. Actual subsequent evidence
must still pass the existing checks. A source lag beyond the whole measurement+expiry
span cannot be fixed by phase scheduling and must reject honestly.

Use the existing actual production scheduling regression in
`ios/FilmModelTests/NativeOwnedCandidatePublisherTests.swift` (history:
`2026-09-25-ordinary-camera-adaptation.md`, run13 scheduling correction) to reproduce
this delay first, implement the smallest coherent scheduling change, and only then
run one native4second/6second-profile comparison. Avoid another simple GOP/latency
sweep. Other unchanged simulator evidence remains reusable.
