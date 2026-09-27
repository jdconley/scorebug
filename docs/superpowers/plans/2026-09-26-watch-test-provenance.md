# Paired Watch test provenance

## Goal

Make the native paired test accept only the current run's real WatchConnectivity offer and prove that exact pairing before sending scoring commands. A retained application context from an earlier run must never be sufficient to start scoring.

## Confirmed failure

`physical-paired-live-ilu6I7` entered the Watch test after passcode approval. It tapped an offered setup and entered durable pending redemption. The phone runner timed out enabling automation before its body; the current lab issued zero Watch pairings. The offer therefore came from another run. The original server outcome remains unknown.

## Design

- Require a validated expected match UUID in the companion test runner before app launch. It is an assertion identity, not a fixture offer, endpoint or credential.
- Expose only nonsecret offered, pending and paired match/pairing identities through accessibility metadata.
- Wait for an offer for the expected match. Bind the selected pairing identity, recheck before tapping, and require matching paired identity before takeover or scoring.
- Report existing pending setup explicitly; never discard or replace it automatically.
- Wire the ordinary paired simulator launcher, the paired archive launcher and the physical artifact wrapper to their newly created match identity.
- Preserve normal setup/recovery semantics. Recover physical pending state only through the original server's receipt-first protocol after identifying its ownership.

## Todo

- [x] Implement identity gate and all launcher inputs.
- [x] Verify foreign/missing offers, later matching offer, invalid expected ID, pending preservation and paired mismatch. Include actual model coverage for non-UUID pending match IDs and restored readiness.
- [x] Independent specification and code-quality reviews.
- [ ] Identify the existing pending test pairing and safely recover its server outcome.
- [ ] Rebuild signed products, record immutable input hashes, then retry on ready hardware.
- [ ] Inspect native scoring, clean archive, proxy overlay and mock MP4 evidence; retain any failure without overstating qualification.

## Current status

Implementation and local verification pass:46 Watch model tests and37 focused tests. Both independent reviews approved the exact11-file scope. End-match modal accessibility remains a hardware qualification check; missing metadata fails closed. Recovery investigation identified a historical candidate but needs live Watch identity confirmation. No capture is active. The pending phone automation question remains unanswered. Device passcode readiness and application pairing state are separate prerequisites.
