# Retry failed Watch setup notices in the foreground

## Evidence and scope

The fresh unchanged `ff7debd` paired probe (`paired-watch-wzOACx`) fails before
setup: no pairing or scoring requests reach the isolated API. The Watch reports
ACX error 43 and a missing companion although both apps install with matching
identifiers. All 1,167 tracked hashes stay unchanged and both owned simulators are
deleted. This remains a failed actual WatchConnectivity qualification.

Independent review also found an application recovery gap: `WatchScoringModel`
caches its notice before the callback, and the app discards a thrown context
publication error. An unpaired foreground poll returns without retrying. A
transient publication failure can therefore require another foreground wake.
The retained simulator logs do not prove that this gap caused their persistent
companion database failure.

## Bounded change

- Make the notice callback throwing and cache a notice only after the native
  context publisher accepts it. Acceptance means local publication, not peer
  delivery or server acknowledgment.
- Retry an unaccepted current notice on the existing foreground poll (normally
  every two seconds), including before initial pairing. Keep only the current
  persisted setup's notice; do not queue historical notices.
- Do not start a timer, retry while suspended or busy, or resend an unchanged
  accepted notice on every poll. A foreground wake may advertise again as today.
- Publication failure must not prevent direct HTTP scoring, overwrite command
  outcomes, or change any setup credential, durable command or haptic behavior.
- Propagate the native adapter's publication error to the model; keep its
  activation-time latest-context replay unchanged.

## Verification

1. Regression tests for failure followed by foreground recovery, persistent
   failure with one attempt per poll, accepted deduplication and wake resend,
   suspension/busy suppression, paired scoring independence, and latest-state
   publication after setup changes. First establish behavioral failures with
   only the throwing callback seam introduced.
2. Run the Watch model suite, filming/model integration suite, native Watch UI
   workflow, and combined phone/Watch build. Inspect each original result.
3. Request independent review, update the parent plan and Watch status with exact
   evidence. Do not reclassify the paired baseline or claim physical routes work.

## Implementation and verification complete

The app propagates context-publication errors, and the model caches only accepted
notices. A failed newer publication also invalidates the old cache: reverting to
an earlier setup must overwrite the adapter's retained failed context. An attempt
revision prevents a failed HTTP poll's setup restoration and its terminal retry
from publishing twice. A canceled poll cannot retry while a scoring action owns
admission. Existing bounded wake/refresh recovery may publish installed setup more
than once; no new loop or background task is introduced.

- Initial regression: nine assertion failures with only the throwing callback
  seam introduced, preserving the old cache behavior (`watch-notice-red`).
- Failed-pending-context regression: two failures before clearing the old cache
  (`watch-notice-reverted-red`). Both original failures remain in the evidence.
- Final Watch model/gate suite: **54 pass**, including nine new regression cases.
- Filming/model integration: **502 pass**, including two Watch models transferring
  scoring during one real clean A/V recording (injected companion transport).
- Native Ultra 2/watchOS 26.2: **pass** at `native-watch-8NXAx7`, 62.989 seconds,
  six exact server outcomes, Keychain relaunch recovery and inspected screenshots.
  Initial setup is injected; this does not qualify WatchConnectivity.
- Combined unsigned phone/Watch Release build: **pass**. Phone arm64 and embedded
  Watch arm64/arm64_32 are present; the simulator setup key is absent.
- Independent review approves the correction. The joined commands and exact
  results are in `artifacts/qa/watch-notice-verification.json`.

One fresh paired run after the fix (`paired-watch-t9PB1Q`) **still fails** at the
actual setup handshake. Watch system logs again show ACX43 and a missing companion;
the API receives zero pairings, score commands or broadcast commands. The fix is
not a resolution of that simulator failure. All 1,167 frozen tracked contents
remain unchanged through native verification, and all three owned devices from
the native/paired checks are removed. See `watch-notice-source-verification.json`.

The actual paired workflow and physical route gates remain open. Do not repeat the
same simulator experiment without a new diagnostic or a concrete configuration
hypothesis. Bounded, payload-free activation/publication/delivery observations can
separate context acceptance from companion discovery in a future investigation.
