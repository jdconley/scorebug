# Delivery focus — September 28

Starting commit e40294e, authoritative scorebug-local-validation checkout. User asks
for faster iteration, fewer tests, and simulator-first delivery.

Reviewed the current plan, acceptance matrix, full simulator handoff, worker pipeline
and hands-on launcher. The complete simulator feature workflow already has accepted
media and UI evidence. No missing core implementation was established by this review.
The previous handoff over-prioritized additional fault/platform qualification.

Updated the plan with a concrete working simulator configuration and explicit
unsupported/unqualified configurations; retained every open fault and qualification
checkbox. Added the hands-on launch path to the main README and changed NEXT to
prevent unnecessary qualification from becoming a prerequisite to using the apps.
No production code, test expectations, quality settings or acceptance results changed.

A read-only devicectl check before refocusing reported phone and Watch unavailable.
No automation/signing/install/passcode action followed. The proposed AMD64 container
smoke was cancelled before starting; it would not close a simulator feature gap.

Verification: documentation diff and relative Markdown targets only. No app build,
UI test, media capture, broad suite or soak. Existing e40294e simulator acceptance is
reused; no new runtime claim. Hardware and external acceptance remain deferred.

Next: use the accepted simulator path, and batch fixes for concrete failures. An
abrupt-tail investigation must begin with a bounded hypothesis using saved evidence;
it is not a reason to restart all passing workflows. Simulator UHD/congestion and
colocated VideoToolbox limitations remain open as stated in the plan.
