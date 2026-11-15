# Native deadline failure resets

Continue from `d21aab2`, whose actual 1.5-second simulator experiment proves
healthy windows, a zero-FPS one-second window and 35/60 missing frames over two
seconds without interrupting the archive. Integrate these existing classifications
with the approved progressive policy; retain all remaining recovery/headroom gates.

The one-second lane triggers strictly below 24 on-time FPS. The two-second lane
triggers strictly above 5% missing+late frames. Only fully classified windows
produce these precise failure signals. Both may request a minimum reset; neither
adds healthy recovery time. Keep independent lane watermarks because the windows
overlap. Preserve the controller's global decision sequence, priority over trial
rollback, expiry and acknowledgment rules. At the minimum, record degraded state
and restart the existing recovery hold without recreating the encoder.

Add a Core `DeliveryFailure` with current attempt/revision/sequence, one/two-second
source interval, exact classified counts and conservative observation-time lower
bound. Reject malformed counts, wrong scope, overlap in the same lane, old windows
(the existing two-second source-window age limit), stale sample bounds (>250 ms),
and intervals before the current native acknowledgment. No legacy-policy action.

Native integration must classify against current ownership after asynchronous
work. A thread-safe revocable delivery-context lease will prevent queued evidence
from initiating a reset after detach, omission, expiry or worker context replacement.
Same-context reports can retain authority while explicit sample age still bounds
decisions. The native owner rechecks its configuration, revision and lease immediately
before consuming evidence. Once a valid failure has latched a reset, later telemetry
loss cannot erase that known failure; native dispatch retains the existing attempt,
revision, advice-expiry and acknowledgment checks.

- [x] Core failure signal and direct-minimum decision with threshold, overlap,
      stale/scope, minimum no-op, trial precedence and recovery-no-credit regressions.
- [x] Native revocable context authority, classified-window adapter and owner
      integration with tests for stale work, duplicates, context changes and teardown.
- [x] Driver scheduling and evidence export; explicit fixture activation only.
      Keep production automatic quality disabled until full qualification.
- [x] Independent review, required suites/builds and actual simulator fault run;
      independently reconcile decisions with raw deadline evidence and archive output.
      Freeze evidence and commit; qualify higher-profile writes/recovery separately
      where this run cannot prove them.

## Owner checkpoint

Core adds 13 regression tests for exact thresholds, malformed/stale/wrong-scope
evidence, independent lane ordering, trial/reset priority and no fabricated recovery
credit. Native tests prove a classified loss window can dispatch and acknowledge a
minimum-rate reset through the owner, duplicate consumption cannot dispatch again,
and the ordinary source-window watermark remains untouched. This uses injected
native operations and does not prove a physical encoder rate change.

Classification binds the exact context-authority instance. Omission, expiry,
context change, stop and model destruction retire that authority permanently. A
replacement authority cannot reauthorize an older classification. Independent
review also found the short-status-expiry race: a 20 ms status could enter the
actor after 30 ms while still below the 250 ms sample-age cap. A failing-then-passing
regression now requires a live status/freshness check at admission, independently
of the model's periodic revocation and the classification's frozen lower bound.
An already consumed valid failure still keeps its reset intent after later
telemetry retirement, as required by reset precedence.

Core and native owner/authority reviews are approved. Driver scheduling, decision
export, explicit live-fixture activation and the new actual reset experiment remain
open. Production automatic quality remains disabled. The next checkpoint should
return classified observations from the monitor, consume them in the driver's
existing serialized cycle and export enough evidence to independently reconcile
each reset. Isolate the deadline path from the separately qualified no-progress
watchdog in the explicit test fixture so the earlier watchdog cannot mask it.

Verification: 385 Core tests and 280 native model tests pass, with ARM64 simulator
build-for-testing and unsigned combined iPhone/Watch Release builds. All 276 prior
frozen evidence files remain unchanged. This checkpoint's source and evidence
hashes are in `artifacts/qa/deadline-reset-final-verification.json`.

## Verified driver checkpoint

The serialized driver now consumes the monitor's classified observations, with
admission still controlled by the native owner. The explicit simulator flag
`SCOREBUG_TEST_DEADLINE_RESETS=1` requires the controlled decoder-pause experiment,
1.5-second delivery deadline, and cadence evidence. This isolated mode suppresses
the earlier no-progress watchdog and legacy source recovery credit. The default
mode retains its existing behavior; production automatic quality remains disabled.

Each deadline decision exports its classification time, original delivery receipt,
worker/publication context, frame counts, source interval, sequence, revision and
conservative observation bound. The independent Node verifier must reconcile these
with raw report deltas and the owned decoder pause, check freshness again at
admission, and reject any action at the already-minimum profile. The first actual
run qualifies minimum holds only. Higher-profile deadline-triggered writes,
automatic recovery and candidate headroom remain separate gates.

Actual simulator run `native-app-DcUNqI` now qualifies the isolated deadline path.
The 2.051-second owned decoder pause produced one admitted one-second failure with
30 expected frames, zero on-time frames and 30 missing frames. The controller
reported `freshFrameFloor`, `stalled` and `minimumProfileInsufficient` and held the
already-minimum profile without recreating the encoder. There were no watchdog,
applied-write or failed-publisher events. Two later observations were rejected at
owner admission for freshness, without interrupting publishing.

The verifier reconstructs 840 raw reports and all 150 deadline windows: 134 are
classified and 16 remain freshness-unknown. The one-second lane contains 86 healthy
windows; the two-second lane contains 44. These overlapping windows give no recovery
credit. Review closed a verifier admission gap by checking intervening omission or
context/scope replacement, including sticky retirement after original ownership
returns. Null startup observations also have a failing-then-passing regression.

The independent 1080p archive finished with 3,716 fully decoded frames, zero source
loss and 61/61 audio markers. The 240p live output fully decoded with 3,293 frames,
zero eventual source loss and 54/54 audio markers. Eventual delivery does not erase
the measured deadline miss. All 385 Core, 286 native model and 1,378 tooling tests
pass, along with ARM64 simulator build-for-testing and unsigned combined iPhone/Watch
Release builds. Specification and quality reviews are approved. Frozen evidence:
`artifacts/qa/deadline-driver-final-verification.json`.

Next qualify a deadline-triggered higher-profile encoder transition, then candidate
actual cost/headroom and controlled recovery. This run proves a minimum hold, not
an actual resolution change, automatic recovery, physical phone/Watch behavior or
remote worker performance. Production automatic quality remains disabled.
