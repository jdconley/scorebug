# September 28 — simulator-first iteration reset

Starting `640aee3`, clean, in the local-validation worktree. The user explicitly
asked for faster progress, fewer tests after small changes, and hardware deferral.

Reviewed the current plan, acceptance matrix, handoff, and retained simulator
candidate/worker-capability diagnostics. The required functional paths have local
passing evidence; simulator congestion/UHD and interrupted output tails still have
explicit failures or limits. No passing status was widened.

Corrected NEXT, which had promoted physical readiness to the next action despite
the requested simulator-first priority. Current device prompts are no longer a
prerequisite. Tightened the plan's iteration policy: batch fixes, one relevant
check, checkpoint-only full vertical, reuse saved artifacts, no routine device
polling or unchanged soaks. No production changes, tests, captures, or hardware
operations were performed. Documentation diff checked with `git diff --check`.

Next: investigate the saved congestion/media failures for a concrete app defect or
runtime limit. Do not repeat the isolated simulator UHD failure or the already
passing sustained native 4K run. All delivery TODOs remain in the plan.
