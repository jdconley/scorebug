# September 25 checkpoint: Exact transferred-application rejection settlement

**Imported history, not a reconstructed whole session.** Extracted during plan cleanup from [guarded admission](../superpowers/plans/2026-09-25-owned-application-admission.md#core-transferred-application-checkpoint) at `b65ca7fe1d58be9ac27e88a63c67867d428f1b10`. Original session boundaries/times are unknown. Implementation commit: `055b0b5`. Results below describe that checkpoint, not a new verification run. Repository-relative artifact paths are rooted at the checkout; ignored artifacts may exist only in the original workspace.

## Recorded commands and results

Exact command lines were not retained in the imported checkpoint text or matching exit records inspected. Use the named evidence logs below; no command is reconstructed here.

## Decisions, verification, failures and next work (imported)

Core now retains the exact measurement/application pair after transfer, separately
from the active application slot that telemetry may revoke. Its explicit
`settleCandidateApplicationRejection(_:for:at:)` consumes only that pair, counts
failure once and requires fresh recovery coverage, without changing applied
settings or creating a resolution reset. Existing downward work and reset intent
remain intact. Identity and scope checks precede clock changes.

An unresolved transfer blocks competing measurement/upward admission. Exact
successful acknowledgement consumes it; actual applied-revision change permits
non-counting retirement through `retireObsoleteCandidateMeasurement`. Uncertain
or partially applied failures retain the prior reset/shutdown contract. This pure
policy API cannot itself prove native cleanup or lack of earlier profile effects;
those remain obligations of the app's owned application route.

**28 focused / 487 full Core tests pass**, including 11 new transferred-application
cases. All processes joined. Behavioral RED evidence exercised the former
`acknowledge(applied: nil)` path and reproduced its incorrect reset/ownership
behavior before using the new API. Evidence:
`artifacts/qa/transferred-application-core-{red,focused-final,full}-20260925.log`.
Independent specification and quality reviews approve the Core-only checkpoint.

## Current handoff

Both independent reviews approve this checkpoint. Later checkpoint counts supersede earlier counts; full app integration and fresh automatic post-restoration qualification remain open. Current immediate priority is the authorized physical vertical in [NEXT](NEXT.md).
