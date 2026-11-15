# Fresh quality advice and bounded native execution

The previous turn made verified progress: the reader survived and recovered after
packet loss. Native pressure then failed at the higher profile trial, with only
227 ms left on source-window advice; healthy native format replacement previously
took 340–430 ms. The deterministic application regression now reproduces this:
fresh advice dispatched with that remaining time rejects its actual profile receipt
and retires live. Recording remains independent.

Keep the two-second source freshness and recommendation admission limit. Add an
explicit, single-use policy application authorization issued only while the exact
pending recommendation is fresh. Its separate two-second completion budget starts
at admission and covers both profile replacement and verified bitrate assignment.
Completion must match that authorization, the same attempt/revision/recommendation,
and actual native receipts. A second admission cannot renew it. New telemetry or
invalidation revokes it; late, failed, stopped, cancelled or replayed work cannot
advance policy. Legacy direct acknowledgment retains its original expiry semantics.
Do not stretch source freshness or count the application interval as healthy video.

The app owns serialization and must admit immediately before native dispatch, then
validate and acknowledge with the issued authorization. Retain the committed
admission in version-two QA evidence. The independent verifier must check fresh
admission, exact bounded completion, source/revision binding, unique authorization,
and actual profile/bitrate receipts. Version-one artifacts keep their old deadline
checks; absence of new evidence must not grant additional time.

- [x] Preserve failing deterministic regression of the observed remaining budget.
- [x] Test policy admission, expiry, supersession, revocation, replay, failed writes,
      unchanged legacy semantics, and post-ack trial coverage.
- [x] Bind app operations and evidence to authorization; preserve atomic receipts
      and joined stop/cancellation behavior.
- [x] Add failing verifier cases for late/unbound/reused admission and late receipts.
- [x] Run core, app-model, tooling and unsigned iPhone/Watch checks sequentially.
- [x] Repeat unchanged adaptive pressure and independently verify local recording.
      Live media qualification remains failed; see the result below.

The 5.6 fps pressure window is a separate unresolved gate. This change cannot claim
full streaming qualification merely because the higher-profile trial completes.
Timely congestion response, trial/rollback/recovery, source loss, A/V, long soaks,
physical phone/Watch and portable-host checks remain required.

## Causal and review evidence

`quality-admission-causal-red.log` shows the fresh-advice regression failing with
`invalidReceipt`; the first corrected app run passes it. The original advice
expiry stays unchanged, and the actual native operations share admission + 2
seconds. Core tests verify revocation by new telemetry, single-use completion,
failed completion, foreign authorization, unrenewable expiry and legacy semantics.
Actual acknowledged time still anchors subsequent trial coverage.

Review found three edge cases, reproduced before correcting them: a matching
authorization retried after an invalid clock, timeout-only rollback admitted before
probation expired, and a false rejection caused solely by delayed event logging.
Matching failed acknowledgments now consume authorization and reset accumulated
recovery; foreign tokens do not consume it. Version-two verification checks fresh
admission and actual acknowledgment deadlines; subsequent log time may be later.
Timeout-only rollback cannot start before expiry, and a claimed advice issue time
cannot follow native admission. Version-one artifacts retain original checks.

All 292 core, 201 app-model and 949 tooling tests pass after review fixes, as does
the combined unsigned iPhone/Watch Release build. Read-only re-review approved the
corrections. The unchanged native pressure repeat is `native-app-9wQGR3`; its
pre-run source snapshot binds these results to the exact tested changes. This is
not yet a frame-rate or complete adaptive-recovery pass.

## Native pressure result

`native-app-9wQGR3` passes the complete UI workflow and stops publishing normally
after 260 seconds. Actual native profile/encoder receipts match all four committed
changes: decrease at 62.46 seconds, higher trial at 101.90, rollback at 107.96,
and later higher trial at 171.96. The controller reports trial confirmation at
186.40 seconds and stays at 1080p through normal stop. The two upgrades had only
137/91 ms of their original advice lifetime remaining at admission, while actual
completion took 448/467 ms. Both fit their issued two-second completion budget.
This reproduces the formerly failing timing circumstance and confirms the native
operation now completes without retiring the publisher.

Retained analysis binds admission scope/revision/timestamps, actual native format
receipts, native encoder sessions and bitrate receipts. It does not relabel raw
controller confirmation as full independent media/policy qualification: the
complete live gate is still failed. The live output has a −224.9 ms A/V coverage
end difference (100 ms budget), 7440 decoded frames versus 7736 expected after
60-frame acquisition, 43 non-increasing decoded barcodes, and a worst receiver
window of 40 fresh frames in five seconds (8 fps). The frame-count deficit is
3.83%; it is not a complete source-identity loss measurement because concealed or
repeated pictures also fail the independent identity gate. Audio timestamps show
258 ms of aggregate gaps, with the largest about 43 ms. Native encoding itself
produces 7796 frames over five contiguous 1080/540/1080/540/1080 phases.

The clean archive passes: 8136 consecutive source frames at 1080p/30 over 271.2
seconds, all 135 A/V markers, 0.0209 ms maximum marker offset, 9.33 ms A/V end
offset, and no archive rejections or drops. Existing successful runner decode,
probe, barcode and PCM artifacts were independently checked along with archive
terminal counters, without rerunning the completed archive media workload.
The uplink schedule completes its unchanged recovery-traffic qualification; that
does not establish acceptable live media. All owned test/analysis processes are
terminal, and container/simulator absence and collector/recorder closure are
verified before final hashes.

Next investigate faster independently measured congestion response, particularly
the five-second local pressure window after each profile acknowledgment and the
one-second native statistics collection cadence. Preserve the remaining audio,
frame identity, source-loss and ≥24 fps gates. A completed controller trial is not
permission to activate production adaptation. The reconnectable recording fixture,
long soaks, physical iPhone/Watch and other-host qualification remain open.
