# UHD polling and publisher isolation — September 28

Starting8db60e7, clean `codex/local-validation`. Previous turn was progress:
shortened reproduction and confirmed hardware selection. No production fix is
claimed here. All changes are opt-in DEBUG/headless diagnostics; no hardware,
agents, push, broad suite or redundant media decoding.

## Two short comparisons

1. `--direct-uhd on --freeze-uhd-polling on`,55s, source215–345s remux. The new
   diagnostic pauses worker-status acquisition and quality-driver ticking after
   the real UHD application; broadcast ownership and local health keep polling.
   This deliberately disables adaptive reaction and cannot qualify streaming.
   `headless-native-mx1Wwc`, exec23488 joined0, cleanup empty. UHD26s,18SDK raw
   drops by end, app drops0, hardware selected.846UHD receiver frames with
   maximum delta6000/90000. Median sampled UHD native submission33.05ms, max51.73ms.
   Recording/publishing survive. Freezing ongoing adaptive polling does not remove
   the loss, ruling it out as a sufficient explanation.
2. `--fixed-uhd on --fixed-uhd-transition on --owned-uhd-transition on`,35s,
   source250–300s remux. Uses the actual production UHD publisher wrapper and
   bandwidth-probe capability, starts240, manually requests the guarded UHD change
   at5s. No candidate measurement or bandwidth campaign runs. `headless-native-dZDuaa`,
   exec29036 joined0, cleanup empty.92consecutive240frames then909consecutiveUHD
   receiver frames, all deltas3000/90000;0SDK/app drops, hardware selected.
   Max native submission49.71ms (initial/transition), final0.235ms.
   Recording/publishing survive. Production wrapper/initial240 configuration alone
   does not reproduce the sustained slow native calls.

Both incremental FilmModel builds and selected headless XCTest pass their explicit
diagnostic scope. JavaScript syntax and diff checks pass. Each artifact retains
producing source patch/HEAD and hashed `isolation-analysis.json`; patches differ
because the owned-publisher variant was added after the frozen run. No full media
acceptance follows from lifecycle runner success.

## Interpretation and next step

The remaining differentiator is pre-upgrade adaptive measurement/admission work,
especially candidate native encoding versus the bandwidth campaign. Neither ongoing
polling, plain publisher construction, long accumulated state, software fallback,
nor the guarded replacement alone explains the failure. Native candidate terminal
code explicitly drains/stops/clears its codec; resource leakage is not established.
Do not apply more history-copy or queue-size changes based on these results.

Next isolate candidate encoding from bandwidth probing before changing production
behavior. A short measurement warmup followed by the already passing owned-publisher
transition can separate them. Preserve real lifecycle joining and mark this as
diagnostic, not admission proof. Use the55s direct path for any subsequent fix
verification, then the full ladder only after the short path passes.

New flags have strict scope checks: frozen mode requires direct UHD and≤60s;
owned-transition requires fixed-transition (therefore fixed/UHD/audit-off/≤60s/no
outage). Native test checks that polling actually froze or the transition receipt
contains3840×2160. Both process handles joined; no active jobs.
