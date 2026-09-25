# Measured capacity drop and restoration plan

> Use `superpowers:executing-plans`. Autonomous implementation and routine design choices are authorized. No production switch or complete recovery claim is implicit in transport accounting.

**Goal:** Exercise real upload capacity reduction/restoration with the representative match pipeline, prove the applied fault, then independently prove native quality reduction, recovery and continuous clean recording.

**Architecture:** Reuse the owned loopback UDP queue and its timed rate schedule. A new explicit profile holds the existing30ms bidirectional delay and every500th-packet loss constant, starts unlimited, limits forward wire rate to550,000bps at60s, and restores unlimited capacity at120s. Record at least60s after restoration. Native policy receives its normal SRT/receiver evidence; the proxy never tells it to change quality.

**Tech stack:** Node UDP impairment fixture, Swift native publisher, existing lossless pressure evidence and raw media/deadline replay.

## Design decisions

-550kbps is a laboratory stimulus between the current350kbps and600kbps video settings plus audio/protocol overhead, not a promise about actual payload or an industry threshold. The transport verifier must observe offered load above the limited rate, bounded forwarding below its ceiling, and increased queue residence or overflow. Insufficient offered traffic cannot qualify congestion.
- Reuse the existing timer/queue rather than add another proxy or a system-wide network conditioner. A readiness-triggered schedule could avoid runs whose upgrade finishes late but adds a live control/clock boundary. First support the existing fixed schedule; later native qualification must independently prove its baseline confirmation preceded the fault. Never infer causality solely from requested offsets.
- Keep this new profile separate from `measuredUplinkProfiles` until the native route, evidence capacities, clock binding and full causal qualifier are ready. Existing static/full-trial success paths must reject it. A transport-only pass must explicitly deny native adaptation/recovery qualification.
- Use existing bounded queue sizes and token bucket, retaining IPv4/UDP28-byte overhead, SRT header bytes in payload, capped16KiB burst and no change to real production networking. Expected configured drops remain distinct from congestion overflow. Reject oversize, socket errors, foreign peer traffic, queued/pending data at closed join, timeline omission or close-discard.
- Validate every applied phase (not just the last snapshot), monotonic cumulative counters/timeline prefixes, unchanged reverse rate, schedule order/duration, all packet/byte conservation, configured deterministic loss, and the actual limited forwarding budget. Show baseline, constrained and restored traffic spans. Queue observations prove send-attempt accounting, never remote receipt.

## Stage1: applied fault evidence

Files: new `scripts/measured-capacity-uplink.mjs`; new `scripts/test/measured-capacity-uplink.test.mjs`. Reuse `udp-impairment.mjs` and `datagram-timeline-qualification.mjs` without altering existing defaults.

- [ ] Write a synthetic monotonic simulation using the real `DatagramImpairmentQueue`, with exact rate changes, sustained offered load, sufficient drain and bidirectional traffic. Write positive/negative tests before implementation: weak traffic, incorrect rate, early/late/missing phases, altered delay/loss, reversed counters, corrupt/past prefix, rate ceiling, omitted timeline and unjoined closure.
- [ ] Implement immutable configuration factory and independent phase qualifier. Require at least180s observed route,60s constrained phase and60s restored traffic. Return explicit transport-only scope and false native/network recovery flags.
- [ ] Run focused/full tooling tests and read-only review. Run a real loopback UDP180s campaign using the same configuration and bounded joined sockets, qualify its saved result and retain the requested settings/output/source hashes. This proves the fault mechanism only.

## Stage2: native integration (must remain incomplete after transport-only work)

- [ ] Add an explicit native capacity recovery selector, mutually exclusive with steady successful-trial and decoder-fault modes; validate host and Swift fixture selectors before resource creation. Select recovery-budget transport policy explicitly.
- [ ] Provide bounded180s cadence/delivery/quality exports without reusing a misleading repeated-decoder flag. Reuse512-row/byte budgets where appropriate, preserve historical formats/defaults and fail overflow closed.
- [ ] Bind applied proxy phase times to native observations with independently bounded clock evidence or an equivalent causal source-frame proof. Prove confirmed360p before the actual limit, a subsequent owned pressure/deadline reset, lower240p stable delivery after restoration, and later fresh measured ramp-up. Do not convert stale/unknown windows to healthy or grant credit during the fault.
- [ ] Run the frozen real-match app workflow, full archive/live decoding, scoring/glyphs and phase audio checks. Preserve failed artifacts, fix actual defects from evidence, rerun only for changed code or a distinct experiment.
- [ ] Add a true outage campaign after capacity recovery; do not label a positive-but-small bitrate as a complete outage. Qualify production integration/wider ladder and physical devices separately.
