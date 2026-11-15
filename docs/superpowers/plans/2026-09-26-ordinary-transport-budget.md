# Ordinary upload recovery budget comparison

**Goal:** Determine whether the actual120ms publishing-hop SRT recovery budget contributes to the observed720p collapse, without changing app policy or declaring a media pass from native ACKs.

**Architecture:** Expose the control plane's existing `SRT_PUBLISH_PEER_LATENCY_MS` through an explicit local-lab option. Preserve the unset behavior and clear ambient values. The ordinary720 runner forwards the option only to the server and records the requested value in its result and lab setup. Actual native sender-delay evidence must independently establish the negotiated value. No decoder deadline, worker read URL, queue bound, encoder recipe or archive change.

**Execution:** Continue the authorized plan inline with focused tests and independent source review. Node tooling only; current Swift source stays unchanged.

- [x] Add failing option tests in `scripts/test/device-lab-options.test.mjs` and `scripts/test/ordinary-native-app.test.mjs`: explicit120/700/2000 accepted; malformed/out-of-range/noncanonical values rejected; API invalid types reject before allocation; omitted option unchanged; ordinary override requires recovery720.
- [x] In `scripts/device-lab.mjs`, parse `--publish-peer-latency-ms` as a canonical integer120–2000, validate API values before allocation, forward its decimal string to `startScoringTestServer`, and record `requestedPublishPeerLatencyMs` only when explicit. In `scripts/test-ordinary-native-app.mjs`, accept/forward the option for recovery720 and record it in the result; never place it in app launch environment.
- [x] Run `node --test scripts/test/device-lab-options.test.mjs scripts/test/ordinary-native-app.test.mjs`, formatting/checks and independent review. Commit the reviewed source before capture.
- [x] Run the same ordinary720 lane/600s verified fixture with `--publish-peer-latency-ms 700`. Keep750kbps cap and existing phase/recording deadlines. Preserve any failure and join all owners.
- [ ] Collect actual native export/attachments, verify negotiated delay, replay native/transport/geometry separately, then run existing three-output media checks. Compare with `ordinary-native-TJzyrf` under the original strict1500ms decoder contract. If delay prevents progression, report that failure rather than changing another variable mid-run.

This comparison tests one hypothesis. A longer recovery budget cannot repair arbitrary overflow; packet bursts, encoder replacement and emergency descent remain possible follow-up causes. Existing low-latency/frame-delay and cadence-pacing experiments must be reused before proposing equivalent work. Physical paired testing takes priority after a real Watch unlock readiness change.

The existing pressure classifier derives thresholds from negotiated sender delay. This comparison therefore measures the parameter’s complete effect, including those derived limits; it cannot attribute any improvement solely to retransmission time.

## Current result

Requested700ms run fails the initial240p policy-ready gate under strict1500ms; no cap or ramp occurs. All three recordings pass frame/audio/glyph checks at30fps. This is clean initial media, not recovery qualification. Actual socket-delay readback is absent because there was no applied transition; requested-value propagation is recorded. Preserve the failed workflow. Next: make the production broadcast timing contract coherent, retaining strict1500 as a benchmark and unchanged report/loss/stall checks, then repeat the full recovery test.
