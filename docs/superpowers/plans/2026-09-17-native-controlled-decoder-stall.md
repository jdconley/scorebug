# Controlled native decoder stall implementation plan

Continue the executing-plans/TDD workflow inline in the local validation worktree.

Exercise real worker decoder silence and the native progressive controller while
retaining fixed240 publishing and independent archive capture. Add explicit
SCOREBUG_TEST_DECODER_STALL=1, requiring the existing cadence-report fixture. Run
one progressive controller whose ladder contains only the already qualified minimum;
there is no upward candidate. A real stall must produce a fresh scoped native
stalled/minimum-insufficient decision without recreating the unchanged encoder.
This measures the minimum-hold decision, not a reset write from a higher profile.

After 20 seconds of producing output, pause only the test worker's owned FFmpeg
child for 1.8 seconds, then resume it. Resolve the worker/guardian/decoder parent
chain and process start identities without reading process arguments. Revalidate
identity before every signal, bound subprocess queries, resume in finally, and join
fault cleanup before terminating the worker. Preserve fault and failure evidence.
No production worker or guardian protocol changes are required.

Join native decision scope/progress/lower-bound timestamps with the original native
cadence audit. Require current attempt/receipt, explicit worker age >=1 second,
actual admission age <=250 ms, and a conservative first decision delay <=1.5 seconds
from last decoder progress. Do not compare unrelated Node and Swift clock epochs.
Require resumed decoder progress and no duplicate minimum write. Keep the existing
strict media verifiers initially: a pause may reveal real packet loss/recovery issues;
retain those failures rather than labeling intentional disruption as a clean pass.

- [x] Write failing owned-process, opt-in and reaction-proof tests.
- [x] Implement bounded pause/resume fixture and native progressive minimum mode.
- [x] Run affected tests and Apple builds, then an actual simulator/SRT/RTMP run.
- [x] Inspect stall timing, resumed media and independent archive integrity; fix
      demonstrated defects or document the precise remaining gate with evidence.
- [x] Freeze results, update main plan and commit.


## Findings from the first actual run

`native-app-vuL6B7` completed its owned pause/resume and recorded exactly one native
minimum-insufficient stall decision. The independently joined report bounds that
decision to 1.270 seconds after last decoder progress, with 225.071 ms admitted sample
age. The run stopped qualification at the fixed-profile cost verifier: the verified
initial bitrate acknowledgment changed the configuration and moved the first cost
anchor by 16 source frames. The legacy verifier correctly rejected its unsupported
anchor assumption. Add an explicit initial-receipt mode that requires the same native
encoder/generation/configuration, a numeric receipt boundary before the first old
cost interval, and exact reconstruction of every retained interval. Legacy fixtures
retain their original anchor rules. New traces include full CMTime receipt metadata.

The same run recorded 223 cadence-freshness rejections from repeated local reads of
an already consumed report. This erased independent source-window recovery coverage.
Use a per-response local receipt identity, retained by copies, to consume successful
cadence input once. Every read still validates current native ownership; new stale
responses still reject and revoke recovery. A consumed downward-only sample supplies
no ongoing health credit and cannot turn into a new stall as it ages. Regression tests
first reproduced the lost four-second recovery and now preserve it without allowing
new stale reports or changed receipts. Rerun the actual fixture after these fixes;
do not relabel the first overall run as passing.


## Verified rerun

`native-app-hnaYMv` completed with exit 0 after both fixes. All 1,253 tooling,
348 Core and 250 native model tests pass, together with ARM64 simulator and unsigned
combined iPhone/Watch Release builds. The exact runtime matches all 765 hashes in
`artifacts/qa/controlled-stall-runtime-source-v3.json`.

The fixture paused its owned decoder for 1,969.945 ms. Exactly one native stall
sample was admitted at 234.230 ms conservative age. Raw worker/native timestamps
bound the minimum-hold decision to 1.443033 seconds after last decoder progress;
local raw-report receipt to decision was 10.430 ms. Advancing decoder progress was
observed again 777.239 ms after the decision. There were no encoder writes after
bootstrap, no live-owner failure and no duplicate stall decision. The bounded trace
contains three freshness rejections, down from 223 in the first run; fresh cached
input is consumed once while new stale input still rejects. This single rerun does
not establish a percentile or a general worst-case latency guarantee.

All 734 settled native reports across 97.126 seconds fit the 250 ms helper freshness
budget. The maximum usable-report gap was 157.247 ms. This audit timing is measured
before the driver's extra local residence, so its maximum need not equal admission
age at the eventual decision.

The native encoder produced 3,298 consecutive frames (157 through 3,454). Saved live
media contains 3,263 consecutive frames after 35 acquisition frames; the independent
1080p archive contains all 3,669 frames (0 through 3,668). Both fully decode and pass
the unchanged audio/coverage verifiers. The intentional decoder pause interrupted
real-time delivery; eventual saved-frame continuity does not erase that interruption.
The owned encoder, worker and recorder exited with code 0 and cleanup was joined.

The independent verifier reconstructs the actual receipt boundary (frame 172), first
new-configuration cost anchor (173), and all eight retained cost windows from raw
encoder/output callbacks (3,951,549 payload bytes). It separately joins the actual
stall report, confirms resumed progress, decodes raw frame identities and rejects
six damaged reaction proofs. Both independent verification files and both actual
runs are retained, including the first overall failed qualification.

## Remaining gates

This fixed-minimum experiment qualifies real local stall detection/minimum hold.
It does not qualify a higher-profile reset write, recovery increases, sustained
on-time frame delivery, disconnect/reconnect, physical devices or remote networks.
Next exercise a controlled higher-profile-to-minimum native reset with actual
receipt/media checks, then complete expected-source/deadline reconciliation and
candidate cost/headroom before enabling production progressive adaptation. Keep
normal minimum startup and the independent archive behavior in place meanwhile.


## Review follow-up

Independent review found that the reaction checker did not compare the complete
native receipt on every trace event. Eleven new regression mutations first failed
and now reject changed/missing receipts, acknowledgments, profiles and revisions.
The actual `native-app-hnaYMv` raw trace passes the stricter checker unchanged;
three damaged copies of that actual trace reject, and a separate Python check
confirms every receipt and acknowledgment equals bootstrap. Only the post-capture
checker and its tests changed after the media run. The original v3 runtime hashes,
Apple builds, media and qualification files are preserved; checker v4 hashes and
requalification are recorded separately. The full tooling suite passes 1,253 tests.
