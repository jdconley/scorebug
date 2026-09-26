# Production probe sizing and transport estimate

> Use superpowers:subagent-driven-development, with specification then quality review. Autonomous implementation is authorized by the existing user request.

**Goal:** Supply ordinary camera integration with an explicit production admission estimate and a bounded probe plan for the next candidate, without importing laboratory IPv4 accounting or a fixed12Mbps probe.

**Boundary:** This slice prepares runtime construction. Ordinary camera enablement, backend selection, physical tests and wider-profile qualification follow. Keep existing lab evidence and defaults unchanged.

## Design

Use the existing admission validation and authority joins. Add an explicit production SRT entry point using64bytes of base-header allowance per measured transport message. Preserve `laboratoryIPv4` at44bytes with its original audit schema. Both cost the measured complete MPEG-TS candidate using the shorter source/submission duration; the existing1.25 admission margin and delivered receiver intervals remain unchanged. The production estimate covers ordinary unfragmented IP headers, not arbitrary outer-link cost; it is combined with observed same-path delivery and pressure/media feedback. See [source research](../../research/2026-09-25-srt-transport-cost.md). Production admission must not export a misleading legacy laboratory witness.

For probe scheduling only, estimate final padding demand as `ceil((candidate.videoBitRate + audioBitRate) × 1.5)`. The1.5 factor combines a nominal20% mux/framing allowance with the existing25% headroom target; it is an engineering starting estimate, not an upper bound or an industry-standard constant. The initial stage uses half that final rate, followed by the final rate. Preserve existing0.8s initial and0.5s final holds, source-coverage waiting, native12Mbps/16MiB/60s bounds,300ms leases and pressure checks. Actual measured candidate cost and receiver delivery still decide admission; scheduling math grants no authority.

Use the publisher's actual128kbps AAC configuration through one shared named value, avoiding a second silently divergent literal. Reject impossible rates or unsupported plans rather than clamp them and imply support. Current24Mbps4K cannot fit the existing12Mbps probe cap and stays outside the automatic ladder until that capability is deliberately extended and qualified.

Resolve the next-profile plan exactly once from the candidate context when constructing its lease, and retain that immutable plan through binding/snapshot/cleanup. Existing explicit fixed-plan construction remains available for tests and laboratory compatibility. Do not reread a mutable plan provider after allocation. Known360p/540p/1080p candidates yield different rates below the cap; a later attempt can select another candidate after prior retirement.

## Tasks

- [x] Add failing admission tests for production64byte accounting across short/full/mixed TS messages, actual audio-inclusive measured cost, shared validation failures, and unchanged laboratory values/schema. No fixed44 SRT counter may substitute for measured candidate packetization.
- [x] Add failing plan tests for next-profile selection, shared AAC configuration, bounded rates, unsupported4K rejection, immutable per-attempt selection and final binding. Verify failed plan construction leaves no allocated native owner or stuck policy registration.
- [x] Extract shared admission validation without weakening freshness, receipt, scope, interval conservation or revocation. Keep production and laboratory entry points explicit; continuous production creates no laboratory witness/history.
- [x] Implement bounded per-candidate plan selection and use it in the owned lease. Preserve existing fixed-plan API, laboratory ladder and cancellation/retirement behavior.
- [x] Run affected admission/owned suites and relevant streaming configuration tests, then fullFilmModel and arm64 Release simulator build. Preserve failed logs and join processes.
- [x] Commit code/tests; complete independent specification and quality review. Update the current plan/session log, then proceed to ordinary camera integration with the continuous delivery consumer and selected worker limits.

No policy timing, SRT buffers, archive behavior, device provisioning or lab audit budgets change in this slice. Probe defaults require native/phone validation as part of the subsequent integration; passing unit tests does not establish mobile-network capacity or media quality.
